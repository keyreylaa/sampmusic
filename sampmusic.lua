--[[
    SAMP MUSIC — pemutar musik lokal untuk GTA: San Andreas Multiplayer (Android).

    Target   : MonetLoader 3.8.0+ (LuaJIT / Lua 5.1), Android arm64-v8a
    Deploy   : /monetloader/sampmusic.lua  +  /monetloader/musik/<berkas>
    Backend  : BASS (dipakai lewat API loader) + FFI untuk posisi presisi

    Struktur berkas ini sengaja satu berkas, tapi tetap dipisah per modul:
    config, runtime, log, filesystem, metadata, artwork, audio, player,
    queue, library, tautan, state-UI, GUI, dan titik masuk.

    ---------------------------------------------------------------------
    Copyright (C) 2026 Sena

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <https://www.gnu.org/licenses/>.
    ---------------------------------------------------------------------
]]

local ffi = require 'ffi'
local bit = require 'bit'
local imgui = require 'mimgui'

-- [SENA-TRACE] Jejak panggilan API pemuat.
-- Sampai sekarang crash-nya terjadi di dalam libmonetloader (bukan di libGTASA dan
-- bukan di libsamp), di sebuah pool yang membongkar isinya, dan skrip yang jalan
-- saat itu selalu "SAMP MUSIC". Yang belum diketahui: API mana yang dipanggil
-- tepat sebelum proses mati.
--
-- Blok ini membungkus API audio dan tekstur, mencatat panggilannya ke log loader.
-- Karena klien menyalin ekor log loader ke laporan crash, baris terakhir sebelum
-- SIGSEGV akan menyebut API dan parameternya.
--
-- Matiin jejak: set traceEnabled = false di bawah. Hapus blok ini kalau tidak perlu.
local traceEnabled = true
local function traceCall(name, fn)
    if not traceEnabled or type(fn) ~= 'function' then
        return fn
    end

    local calls = 0
    -- API gambar dan audio selalu dicatat: kalau crash-nya di jalur itu,
    -- baris terakhir menyebut panggilan yang mati.
    local always = name:find('Texture') or name:find('Audio') or name:find('audio') or name:find('image')
    return function(...)
        local count = select('#', ...)
        local parts = {}
        for i = 1, count do
            parts[i] = tostring((select(i, ...)))
        end
        calls = calls + 1
        if always or calls <= 3 then
            print(('[trace] %s(%s)'):format(name, table.concat(parts, ', ')))
        elseif calls == 4 then
            print(('[trace] %s(...) panggilan berikutnya tidak dicatat'):format(name))
        end
        return fn(...)
    end
end

for _, name in ipairs({
    'loadAudioStream', 'releaseAudioStream', 'load3dAudioStream',
    'getAudioStreamLength', 'getAudioStreamState', 'getAudioStreamVolume',
    'setAudioStreamState', 'setAudioStreamPosition', 'setAudioStreamVolume',
    'monet_get_audiostream_handle',
}) do
    _G[name] = traceCall(name, _G[name])
end

imgui.CreateTextureFromFile = traceCall('imgui.CreateTextureFromFile', imgui.CreateTextureFromFile)
imgui.CreateTextureFromFileInMemory = traceCall('imgui.CreateTextureFromFileInMemory', imgui.CreateTextureFromFileInMemory)
imgui.ReleaseTexture = traceCall('imgui.ReleaseTexture', imgui.ReleaseTexture)

-- Semua fungsi pemuat lain (selain modul tabel seperti ffi/bit/imgui) ikut dicatat,
-- tapi dibatasi: tiga panggilan pertama per nama, sisanya hanya dihitung. Dengan itu
-- log tetap terbaca dan tetap terlihat API mana yang dipakai skrip ini.
local traceStandard = {
    print = true, type = true, pairs = true, ipairs = true, next = true, select = true,
    tonumber = true, tostring = true, pcall = true, xpcall = true, error = true,
    assert = true, setmetatable = true, getmetatable = true, rawget = true, rawset = true,
    rawequal = true, rawlen = true, require = true, collectgarbage = true, load = true,
    loadfile = true, loadstring = true, dofile = true, unpack = true, newproxy = true,
    gcinfo = true, module = true, _G = true, _VERSION = true, wait = true,
    setmaxn = true, getfenv = true, setfenv = true,
}

for name, value in pairs(_G) do
    if type(value) == 'function' and not traceStandard[name] then
        _G[name] = traceCall(name, value)
    end
end
-- [SENA-TRACE] selesai

-- Metadata skrip (dibaca loader lewat Script Manager).
if type(script_name) == 'function' then
    script_name('SAMP MUSIC')
    script_author('Sena')
    script_version('1.1')
    script_version_number(11)
    script_description('Pemutar musik lokal untuk SA-MP Android: pustaka musik, '
        .. 'artwork, antrean, pencarian, dan playback kontrol lewat mimgui.')
end

-- Tetap jalan meski game sedang pause, dan tidak reload dirinya sendiri.
if type(script_properties) == 'function' then
    script_properties('work-in-pause', 'forced-reloading-only')
end

-- Tabel modul dideklarasikan di sini supaya modul bisa saling memanggil
-- (mis. Player memanggil Queue, Library memanggil Ui). Isi modul diisi
-- pada bagiannya masing-masing.
local Runtime, Log, Fs, Meta, Art, Audio = {}, {}, {}, {}, {}, {}
local Player, Queue, Library, Links, Ui, Gui = {}, {}, {}, {}, {}, {}

local CFG = {
    title          = 'SAMP MUSIC',
    musicSubdir    = 'musik',
    -- Hanya format yang benar-benar didukung BASS tanpa plugin tambahan.
    extensions     = { mp3 = true, wav = true, wave = true, ogg = true,
                       oga = true, flac = true, aif = true, aiff = true },
    scanBudget     = 2,        -- berkas yang diproses per frame saat pemindaian
    artworkCache   = 16,       -- jumlah texture artwork yang boleh hidup
    artworkMaxSize = 4 * 1024 * 1024,
    tagMaxSize     = 8 * 1024 * 1024,
    tagReadLimit   = 2 * 1024 * 1024,   -- tag lebih besar dari ini dilewati
    headerReadSize = 64 * 1024,         -- metadata non-artwork (FLAC/OGG/WAV)
    defaultVolume  = 0.8,
    urlTimeout     = 20,       -- detik sebelum stream URL dianggap gagal
    messageTime    = 6,        -- detik pesan status tetap tampil
}

local CLOCK_MONOTONIC = 1

function Runtime.detect()
    Runtime.version   = tonumber(MONET_VERSION) or 0
    Runtime.dpiScale  = tonumber(MONET_DPI_SCALE) or 1
    if Runtime.dpiScale < 1 then Runtime.dpiScale = 1 end

    local ok, width, height = pcall(getScreenResolution)
    if ok and width and height and width > 0 and height > 0 then
        Runtime.screenWidth, Runtime.screenHeight = width, height
    else
        Runtime.screenWidth, Runtime.screenHeight = 1280, 720
    end

    Runtime.hasAudio = (type(monet_is_audiostream_available) == 'function')
                    and monet_is_audiostream_available() == true

    -- Jam monotonik untuk mengukur waktu tanpa tertinggal jeda game.
    -- Nama struct dibuat unik agar tidak bentrok dengan cdef milik loader.
    if pcall(function()
        ffi.cdef [[
            struct sampmusic_timespec { long tv_sec; long tv_nsec; };
            int clock_gettime(int clk_id, struct sampmusic_timespec *tp);
        ]]
    end) then
        Runtime.timespec = ffi.new('struct sampmusic_timespec')
    end
end

--- Waktu berjalan dalam milidetik; tidak terpengaruh jeda game.
function Runtime.nowMs()
    if Runtime.timespec and ffi.C.clock_gettime(CLOCK_MONOTONIC, Runtime.timespec) == 0 then
        return tonumber(Runtime.timespec.tv_sec) * 1000
             + tonumber(Runtime.timespec.tv_nsec) / 1000000
    end
    return os.time() * 1000
end

--- Skala ukuran antarmuka. DPI dulu, resolusi sebagai cadangan.
function Runtime.scale()
    if Runtime.dpiScale and Runtime.dpiScale > 0 then return Runtime.dpiScale end
    return math.max(1.0, Runtime.screenHeight / 720)
end

local logOnce = {}

function Log.info(fmt, ...)
    print('[sampmusic] ' .. string.format(fmt, ...))
end

--- Cetak sekali saja per kunci agar log tidak membanjir.
function Log.once(key, fmt, ...)
    if logOnce[key] then return end
    logOnce[key] = true
    Log.info(fmt, ...)
end

function Log.error(fmt, ...)
    print('[sampmusic] ERROR ' .. string.format(fmt, ...))
end

function Fs.init()
    Fs.root     = getWorkingDirectory()
    Fs.musicDir = Fs.root .. '/' .. CFG.musicSubdir
end

function Fs.ensureMusicDir()
    if doesDirectoryExist(Fs.musicDir) then return true end
    local ok = pcall(createDirectory, Fs.musicDir)
    return ok and doesDirectoryExist(Fs.musicDir)
end

--- Baca potongan berkas. offset 0-based, panjang dalam byte.
function Fs.read(path, offset, length)
    local file = io.open(path, 'rb')
    if not file then return nil end
    if offset and offset > 0 then file:seek('set', offset) end
    local data = file:read(length)
    file:close()
    return data
end

--- Kembalikan daftar berkas audio di folder (level pertama saja).
function Fs.listAudioFiles(dir)
    local lfs = require 'lfs'
    local found = {}

    -- lfs.dir mengembalikan iterator dan objek direktori; keduanya wajib
    -- diteruskan ke loop for.
    local ok, iter, state = pcall(lfs.dir, dir)
    if not ok or not iter then return found end

    for name in iter, state do
        if name ~= '.' and name ~= '..' then
            local ext = name:match('%.([%w]+)$')
            ext = ext and ext:lower() or ''
            if CFG.extensions[ext] then
                local path = dir .. '/' .. name
                -- lfs.attributes(path, 'size') memberi ukurananya langsung,
                -- bukan tabel. Kalau diperlakukan sebagai tabel, tidak satu
                -- pun berkas masuk ke daftar dan pustaka selalu kosong.
                local size = lfs.attributes(path, 'size')
                if type(size) == 'number' and size > 0 then
                    found[#found + 1] = {
                        path = path,
                        name = name:sub(1, #name - #ext - 1),
                        size = size,
                    }
                end
            end
        end
    end
    return found
end

-- Semua offset di bawah adalah 0-based (titik awal byte pertama).

local function u16(s, off)
    local a, b = s:byte(off + 1, off + 2)
    if not a then return nil end
    return a + b * 256
end

local function u24(s, off)
    local a, b, c = s:byte(off + 1, off + 3)
    if not a then return nil end
    return a + b * 256 + c * 65536
end

local function u24be(s, off)
    local a, b, c = s:byte(off + 1, off + 3)
    if not a then return nil end
    return a * 65536 + b * 256 + c
end

local function u32(s, off)
    local a, b, c, d = s:byte(off + 1, off + 4)
    if not a then return nil end
    return a + b * 256 + c * 65536 + d * 16777216
end

local function u32be(s, off)
    local a, b, c, d = s:byte(off + 1, off + 4)
    if not a then return nil end
    return a * 16777216 + b * 65536 + c * 256 + d
end

local function u64le(s, off)
    local a, b, c, d, e, f, g, h = s:byte(off + 1, off + 8)
    if not a then return nil end
    return a + b * 256 + c * 65536 + d * 16777216
         + e * 4294967296 + f * 1099511627776 + g * 281474976710656
         + h * 72057594037927936
end

local function synchsafe(s, off)
    local a, b, c, d = s:byte(off + 1, off + 4)
    if not a then return nil end
    return a * 2097152 + b * 16384 + c * 128 + d
end

local function latin1ToUtf8(s)
    if not s:find('[\128-\255]') then return s end
    local out, n = {}, #s
    for i = 1, n do
        local c = s:byte(i)
        if c < 128 then
            out[#out + 1] = string.char(c)
        else
            out[#out + 1] = string.char(192 + math.floor(c / 64), 128 + c % 64)
        end
    end
    return table.concat(out)
end

local function utf16ToUtf8(s, bigEndian)
    local b1, b2 = s:byte(1, 2)
    if b1 == 0xFF and b2 == 0xFE then
        s, bigEndian = s:sub(3), false
    elseif b1 == 0xFE and b2 == 0xFF then
        s, bigEndian = s:sub(3), true
    end

    local out, i, n = {}, 1, #s
    while i + 1 <= n do
        local code
        if bigEndian then
            code = s:byte(i) * 256 + s:byte(i + 1)
        else
            code = s:byte(i + 1) * 256 + s:byte(i)
        end
        i = i + 2

        if code >= 0xD800 and code <= 0xDBFF and i + 1 <= n then
            local low
            if bigEndian then
                low = s:byte(i) * 256 + s:byte(i + 1)
            else
                low = s:byte(i + 1) * 256 + s:byte(i)
            end
            if low >= 0xDC00 and low <= 0xDFFF then
                code = 0x10000 + (code - 0xD800) * 1024 + (low - 0xDC00)
                i = i + 2
            end
        end

        if code < 0x80 then
            out[#out + 1] = string.char(code)
        elseif code < 0x800 then
            out[#out + 1] = string.char(192 + math.floor(code / 64), 128 + code % 64)
        elseif code < 0x10000 then
            out[#out + 1] = string.char(224 + math.floor(code / 4096),
                128 + math.floor(code / 64) % 64, 128 + code % 64)
        else
            out[#out + 1] = string.char(240 + math.floor(code / 262144),
                128 + math.floor(code / 4096) % 64,
                128 + math.floor(code / 64) % 64, 128 + code % 64)
        end
    end
    return table.concat(out)
end

local function decodeText(bytes, encoding)
    if not bytes then return nil end
    bytes = bytes:gsub('%z+$', '')
    if bytes == '' then return nil end
    if encoding == 0 then return latin1ToUtf8(bytes) end
    if encoding == 1 then return utf16ToUtf8(bytes, nil) end
    if encoding == 2 then return utf16ToUtf8(bytes, true) end
    return bytes
end

local ID3_FIELDS = {
    TIT2 = 'title', TT2 = 'title',
    TPE1 = 'artist', TP1 = 'artist',
    TALB = 'album',  TAL = 'album',
    TYER = 'year',   TYE = 'year', TDRC = 'year',
}

--- Ambil byte offset data artwork di dalam frame APIC/PIC.
local function artworkDataStart(content, encoding, legacy)
    local pos
    if legacy then
        pos = 5                       -- encoding(1) + format(3) + type(1)
    else
        pos = 2                       -- encoding(1)
        while pos <= #content and content:byte(pos) ~= 0 do pos = pos + 1 end
        pos = pos + 2                 -- mime\0 + tipe gambar
    end

    if encoding == 1 or encoding == 2 then
        local scan = pos
        while scan + 1 <= #content do
            if content:byte(scan) == 0 and content:byte(scan + 1) == 0 then break end
            scan = scan + 2
        end
        return scan + 2
    end

    while pos <= #content and content:byte(pos) ~= 0 do pos = pos + 1 end
    return pos + 1
end

--- Parse tag ID3v2. baseOffset = posisi tag di dalam berkas (0 untuk MP3),
--- head = header 10 byte tag yang dibaca di offset tersebut.
local function parseId3v2(path, baseOffset, head)
    local result = {}
    if not head or #head < 10 then return result end

    local major   = head:byte(4)
    local flags   = head:byte(6)
    local tagSize = synchsafe(head, 6)
    if not tagSize then return result end

    local total = tagSize + 10
    if bit.band(flags, 0x10) ~= 0 then total = total + 10 end
    if total > CFG.tagMaxSize then return result end

    -- Hanya bagian awal tag yang dibaca: frame teks ada di depan, artwork di
    -- belakang dan hanya butuh offset/panjang, bukan isinya.
    local data = Fs.read(path, baseOffset, math.min(total, CFG.tagReadLimit))
    if not data then return result end

    local idLen, sizeLen, flagLen
    if major == 2 then
        idLen, sizeLen, flagLen = 3, 3, 0
    else
        idLen, sizeLen, flagLen = 4, 4, 2
    end

    local pos = 10
    while pos + idLen + sizeLen <= #data do
        local id = data:sub(pos + 1, pos + idLen)
        if id:find('%z') then break end   -- padding

        local frameSize
        if major == 2 then
            frameSize = u24be(data, pos + idLen)
        elseif major == 4 then
            frameSize = synchsafe(data, pos + idLen)
        else
            frameSize = u32be(data, pos + idLen)
        end

        local frameFlags = 0
        if flagLen > 0 then frameFlags = u16(data, pos + idLen + sizeLen) or 0 end

        local contentStart = pos + idLen + sizeLen + flagLen
        if not frameSize or contentStart + frameSize > #data then break end

        local content = data:sub(contentStart + 1, contentStart + frameSize)
        local field = ID3_FIELDS[id]
        if field and not result[field] then
            result[field] = decodeText(content:sub(2), content:byte(1) or 0)
        elseif (id == 'APIC' or id == 'PIC') and not result.artwork then
            local encoding = content:byte(1) or 0
            local mime = 'image/jpeg'
            if id == 'PIC' then
                local format = content:sub(2, 4)
                mime = (format == 'PNG') and 'image/png' or 'image/jpeg'
            else
                local stop = 2
                while stop <= #content and content:byte(stop) ~= 0 do stop = stop + 1 end
                mime = content:sub(2, stop - 1)
                if mime == '' then mime = 'image/jpeg' end
            end

            local dataStart = artworkDataStart(content, encoding, id == 'PIC')
            if dataStart and dataStart <= #content then
                result.artwork = {
                    file   = path,
                    offset = baseOffset + contentStart + dataStart - 1,
                    length = #content - (dataStart - 1),
                    mime   = mime,
                }
            end
        end

        pos = contentStart + frameSize
        if major == 4 and bit.band(frameFlags, 0x0001) ~= 0 then pos = pos + 4 end
    end

    return result
end

local function parseId3v1(path, fileSize)
    if fileSize < 128 then return {} end
    local data = Fs.read(path, fileSize - 128, 128)
    if not data or data:sub(1, 3) ~= 'TAG' then return {} end

    local function field(start, len)
        local value = data:sub(start, start + len - 1):gsub('%z.*$', ''):gsub('%s+$', '')
        return value ~= '' and latin1ToUtf8(value) or nil
    end

    return {
        title  = field(4, 30),
        artist = field(34, 30),
        album  = field(64, 30),
        year   = field(94, 4),
    }
end

local MP3_BITRATE_V1_L3 = { [0] = 0, [1] = 32, [2] = 40, [3] = 48, [4] = 56,
                            [5] = 64, [6] = 80, [7] = 96, [8] = 112, [9] = 128,
                            [10] = 160, [11] = 192, [12] = 224, [13] = 256,
                            [14] = 320 }
local MP3_BITRATE_V2_L3 = { [0] = 0, [1] = 8, [2] = 16, [3] = 24, [4] = 32,
                            [5] = 40, [6] = 48, [7] = 56, [8] = 64, [9] = 80,
                            [10] = 96, [11] = 112, [12] = 128, [13] = 144,
                            [14] = 160 }
local MP3_SAMPLE_RATE = {
    [3] = { [0] = 44100, [1] = 48000, [2] = 32000 },   -- MPEG 1
    [2] = { [0] = 22050, [1] = 24000, [2] = 16000 },   -- MPEG 2
    [0] = { [0] = 11025, [1] = 12000, [2] =  8000 },   -- MPEG 2.5
}

--- Kembalikan bitrate (kbit/s) dan frekuensi sampel dari frame header MP3.
local function parseMp3FrameHeader(head, offset)
    local b1, b2, b3 = head:byte(offset + 1, offset + 3)
    if not b1 or b1 ~= 0xFF or math.floor(b2 / 64) ~= 3 then return nil end

    local versionBits = math.floor(b2 / 16) % 4
    local layerBits   = math.floor(b2 / 2) % 4
    if versionBits == 1 or layerBits == 0 then return nil end

    local brIndex = math.floor(b3 / 16)
    local srIndex = math.floor(b3 / 4) % 4
    if brIndex == 0 or brIndex == 15 or srIndex == 3 then return nil end

    local isV1  = (versionBits == 3)
    local isL3  = (layerBits == 1)
    local table = isV1 and MP3_BITRATE_V1_L3 or MP3_BITRATE_V2_L3
    local bitrate = table[brIndex]
    local sampleRate = MP3_SAMPLE_RATE[versionBits][srIndex]
    if not bitrate or not sampleRate then return nil end

    local padding = b3 % 2
    local samples = (isV1 and isL3) and 1152 or ((isL3) and 576 or 1152)
    local frameLen = math.floor(samples / 8 * bitrate * 1000 / sampleRate) + padding
    if frameLen < 24 then return nil end

    return {
        bitrate = bitrate, sampleRate = sampleRate,
        samples = samples, frameLength = frameLen, isV1 = isV1,
    }
end

--- Durasi MP3. id3Total = ukuran tag ID3 di depan data audio.
local function parseMp3Duration(path, fileSize, head, id3Total)
    local audioStart = id3Total
    local frameHead = Fs.read(path, audioStart, 4) or head
    local frame = parseMp3FrameHeader(frameHead, 0)
    if not frame then return nil end

    -- Xing/Info: jumlah frame akurat untuk VBR.
    local probe = Fs.read(path, audioStart, 4096) or ''
    local xingAt = probe:find('Xing', 1, true) or probe:find('Info', 1, true)
    if xingAt then
        local flags = u32be(probe, xingAt + 3)
        local frames, bytes
        if bit.band(flags, 0x0001) ~= 0 then frames = u32be(probe, xingAt + 7) end
        if bit.band(flags, 0x0002) ~= 0 then bytes = u32be(probe, xingAt + 11) end
        if frames and frames > 0 then
            return frames * frame.samples / frame.sampleRate
        end
        if bytes and bytes > 0 and frame.bitrate > 0 then
            return (fileSize - audioStart) * 8 / (frame.bitrate * 1000)
        end
    end

    if frame.bitrate > 0 then
        return (fileSize - audioStart) * 8 / (frame.bitrate * 1000)
    end
    return nil
end

local function parseFlac(path, fileSize)
    local result = {}
    local head = Fs.read(path, 0, 4)
    if not head or head ~= 'fLaC' then return nil end

    local offset = 4
    for _ = 1, 64 do
        local header = Fs.read(path, offset, 4)
        if not header or #header < 4 then break end

        local last = math.floor(header:byte(1) / 128) == 1
        local blockType = header:byte(1) % 128
        local blockLen = u24be(header, 1)
        if not blockLen then break end

        local dataStart = offset + 4
        if blockType == 0 then                       -- STREAMINFO
            local info = Fs.read(path, dataStart, 18)
            if info and #info >= 18 then
                -- 20 bit frekuensi sampel + 36 bit jumlah sampel
                local sampleRate = info:byte(11) * 4096 + info:byte(12) * 16
                    + math.floor(info:byte(13) / 16)
                local total = (info:byte(14) % 16) * 4294967296
                    + info:byte(15) * 16777216 + info:byte(16) * 65536
                    + info:byte(17) * 256 + info:byte(18)
                if sampleRate > 0 and total > 0 then
                    result.duration = total / sampleRate
                end
            end
        elseif blockType == 4 then                 -- VORBIS_COMMENT
            local data = Fs.read(path, dataStart, math.min(blockLen, CFG.headerReadSize))
            if data then
                local vendorLen = u32(data, 0)
                local pos = 4 + vendorLen
                local count = u32(data, pos)
                pos = pos + 4
                for _ = 1, (count or 0) do
                    local len = u32(data, pos)
                    pos = pos + 4
                    local comment = data:sub(pos + 1, pos + len)
                    pos = pos + len
                    local key, value = comment:match('^([^=]+)=(.*)$')
                    if key then
                        key = key:upper()
                        if key == 'TITLE' and not result.title then result.title = value end
                        if key == 'ARTIST' and not result.artist then result.artist = value end
                        if key == 'ALBUM' and not result.album then result.album = value end
                    end
                end
            end
        elseif blockType == 6 then                 -- PICTURE
            local data = Fs.read(path, dataStart, math.min(blockLen, CFG.headerReadSize))
            if data and not result.artwork then
                -- semua field blok FLAC memakai big-endian
                local mimeLen = u32be(data, 4)
                local mime = data:sub(9, 8 + mimeLen)
                local descLen = u32be(data, 8 + mimeLen)
                -- lebar, tinggi, kedalaman, jumlah warna = 16 byte
                local lengthOffset = 8 + mimeLen + 4 + descLen + 16
                local imageLen = u32be(data, lengthOffset)
                if imageLen and imageLen > 0 then
                    result.artwork = {
                        file   = path,
                        offset = dataStart + lengthOffset + 4,
                        length = imageLen,
                        mime   = mime ~= '' and mime or 'image/jpeg',
                    }
                end
            end
        end

        offset = dataStart + blockLen
        if last then break end
    end

    return result
end

local function parseOgg(path, fileSize)
    local result = {}
    local head = Fs.read(path, 0, 65536)
    if not head or head:sub(1, 4) ~= 'OggS' then return nil end

    -- Halaman identifikasi: "\x01vorbis" + versi(4) + kanal(1) + frekuensi(4).
    local idAt = head:find('\1vorbis', 1, true)
    if idAt then
        local rate = u32(head, idAt + 11)
        if rate and rate > 0 then result.sampleRate = rate end
    end

    -- Halaman komentar: "\x03vorbis" + vendor_len(4) + vendor + jumlah(4).
    local cmAt = head:find('\3vorbis', 1, true)
    if cmAt then
        local vendorLen = u32(head, cmAt + 6)
        if vendorLen then
            local pos = cmAt + 10 + vendorLen      -- 0-based, posisi jumlah
            local count = u32(head, pos)
            pos = pos + 4
            for _ = 1, (count or 0) do
                local len = u32(head, pos)
                if not len then break end
                local comment = head:sub(pos + 5, pos + 4 + len)
                pos = pos + 4 + len
                local key, value = comment:match('^([^=]+)=(.*)$')
                if key then
                    key = key:upper()
                    if key == 'TITLE' and not result.title then result.title = value end
                    if key == 'ARTIST' and not result.artist then result.artist = value end
                    if key == 'ALBUM' and not result.album then result.album = value end
                end
            end
        end
    end

    -- Durasi: granule posisi halaman terakhir.
    if result.sampleRate and fileSize > 0 then
        local tailSize = math.min(fileSize, 65536)
        local tail = Fs.read(path, fileSize - tailSize, tailSize)
        if tail then
            local lastAt
            local search = 1
            while true do
                local at = tail:find('OggS', search, true)
                if not at then break end
                lastAt = at
                search = at + 1
            end
            if lastAt then
                local granule = u64le(tail, lastAt + 5)
                if granule and granule > 0 then
                    result.duration = granule / result.sampleRate
                end
            end
        end
    end

    return result
end

local WAV_INFO = { INAM = 'title', IART = 'artist', IPRD = 'album' }

local function parseWav(path, fileSize)
    local result = {}
    local head = Fs.read(path, 0, 12)
    if not head or head:sub(1, 4) ~= 'RIFF' or head:sub(9, 12) ~= 'WAVE' then
        return nil
    end

    local offset = 12
    local id3Chunk
    for _ = 1, 64 do
        local header = Fs.read(path, offset, 8)
        if not header or #header < 8 then break end

        local id = header:sub(1, 4)
        local size = u32(header, 4)
        if not size then break end
        local dataStart = offset + 8

        if id == 'fmt ' then
            local fmt = Fs.read(path, dataStart, 16)
            if fmt and #fmt >= 16 then
                local byteRate = u32(fmt, 8)
                if byteRate and byteRate > 0 then result.byteRate = byteRate end
            end
        elseif id == 'data' then
            if result.byteRate and result.byteRate > 0 then
                result.duration = size / result.byteRate
            end
            result.dataSize = size
        elseif id == 'LIST' then
            local data = Fs.read(path, dataStart, math.min(size, CFG.headerReadSize))
            if data then
                local pos = 5      -- lewati "INFO"
                while pos + 8 <= #data do
                    local tagId = data:sub(pos, pos + 3)
                    local tagSize = u32(data, pos + 3)
                    if not tagSize then break end
                    local field = WAV_INFO[tagId]
                    if field and not result[field] then
                        local value = data:sub(pos + 8, pos + 7 + tagSize)
                        result[field] = latin1ToUtf8(value:gsub('%z.*$', ''))
                    end
                    pos = pos + 8 + tagSize + (tagSize % 2)
                end
            end
        elseif id == 'id3 ' then
            id3Chunk = { offset = dataStart, size = size }
        end

        offset = dataStart + size + (size % 2)
        if id == 'data' and result.duration then break end
    end

    if id3Chunk and id3Chunk.size > 10 and id3Chunk.size <= CFG.tagMaxSize then
        local id3Head = Fs.read(path, id3Chunk.offset, 10)
        if id3Head and id3Head:sub(1, 3) == 'ID3' then
            local tag = parseId3v2(path, id3Chunk.offset, id3Head)
            result.title  = tag.title  or result.title
            result.artist = tag.artist or result.artist
            result.album  = tag.album  or result.album
            result.artwork = tag.artwork or result.artwork
        end
    end

    return result
end

--- Baca metadata sebuah berkas audio. Mengembalikan tabel (boleh kosong).
function Meta.read(path, fileSize)
    local head = Fs.read(path, 0, 16)
    if not head or #head == 0 then return {} end

    local result = {}

    if head:sub(1, 4) == 'fLaC' then
        result = parseFlac(path, fileSize) or {}
    elseif head:sub(1, 4) == 'OggS' then
        result = parseOgg(path, fileSize) or {}
    elseif head:sub(1, 4) == 'RIFF' then
        result = parseWav(path, fileSize) or {}
    else
        local id3Total = 0
        if head:sub(1, 3) == 'ID3' then
            local tag = parseId3v2(path, 0, head)
            result.title, result.artist = tag.title, tag.artist
            result.album, result.year = tag.album, tag.year
            result.artwork = tag.artwork
            local tagSize = synchsafe(head, 6)
            if tagSize then id3Total = tagSize + 10 end
        end

        if not result.title and not result.artist then
            local v1 = parseId3v1(path, fileSize)
            result.title  = result.title  or v1.title
            result.artist = result.artist or v1.artist
            result.album  = result.album  or v1.album
            result.year   = result.year   or v1.year
        end

        local duration = parseMp3Duration(path, fileSize, head, id3Total)
        if duration and duration > 0 then result.duration = duration end
    end

    if not result.title or result.title == '' then
        result.title = path:match('([^/]+)$')
    end

    return result
end

local COVER_NAMES = {
    'cover.jpg', 'cover.png', 'cover.jpeg',
    'folder.jpg', 'folder.png', 'folder.jpeg',
    'album.jpg', 'album.png', 'front.jpg', 'front.png',
    'artwork.jpg', 'artwork.png',
}

function Art.init()
    Art.cache = {}
    Art.frame = 0
end

--- Cari berkas cover di samping berkas audio.
function Art.findExternalCover(audioPath)
    local dir = audioPath:match('^(.*)/[^/]+$') or '.'
    local base = audioPath:match('([^/]+)$'):gsub('%.[%w]+$', '')
    local candidates = {}
    for _, name in ipairs(COVER_NAMES) do candidates[#candidates + 1] = dir .. '/' .. name end
    for _, ext in ipairs({ 'jpg', 'png', 'jpeg' }) do
        candidates[#candidates + 1] = dir .. '/' .. base .. '.' .. ext
    end
    for _, candidate in ipairs(candidates) do
        if doesFileExist(candidate) then return candidate end
    end
    return nil
end

local function createTexture(art)
    if not art then return nil end

    -- [SENA-FIX] Renderer mimgui baru ada setelah frame pertama. Skrip uji
    -- gambar (monet-image-test.lua) menunggu imgui.IsInitialized() sebelum
    -- memuat texture; di sini pemuatan bisa terjadi di frame pertama, saat
    -- renderer belum dibuat. Tunggu sampai siap, jangan memuat lebih awal.
    if not (type(imgui.IsInitialized) == 'function' and imgui.IsInitialized()) then
        return nil
    end

    if art.path then
        local ok, tex = pcall(imgui.CreateTextureFromFile, art.path)
        if ok then return tex end
        return nil
    end

    if art.file and art.length and art.length > 0 and art.length <= CFG.artworkMaxSize then
        local bytes = Fs.read(art.file, art.offset, art.length)
        if not bytes or #bytes == 0 then return nil end
        local buffer = ffi.new('uint8_t[?]', #bytes)
        ffi.copy(buffer, bytes)
        local ok, tex = pcall(imgui.CreateTextureFromFileInMemory, buffer, #bytes)
        if ok then return tex end
    end

    return nil
end

--- Tandai texture dipakai pada frame ini.
--- Pelepasan TIDAK boleh terjadi di sini: draw list frame berjalan masih
--- menunjuk texture tersebut, dan RwRasterDestroy akan membebaskannya.
function Art.textureFor(track)
    if not track then return nil end

    local key = track.path
    local entry = Art.cache[key]
    if entry then
        entry.frame = Art.frame
        return entry.tex
    end

    local art = track.artwork
    if not art then
        local cover = Art.findExternalCover(track.path)
        if cover then art = { path = cover } end
    end
    if not art then return nil end

    local tex = createTexture(art)
    if not tex then return nil end

    Art.cache[key] = { tex = tex, frame = Art.frame }
    return tex
end

--- Lepas texture yang tidak dipakai sejak frame sebelumnya, lalu yang paling
--- lama tidak dipakai bila jumlahnya masih melebihi batas.
--- Wajib dipanggil SEBELUM frame dimulai (callback before-frame mimgui),
--- saat tidak ada draw list yang menunjuk texture.
function Art.collectGarbage()
    local previous = Art.frame - 1

    for key, entry in pairs(Art.cache) do
        if entry.frame < previous then
            pcall(imgui.ReleaseTexture, entry.tex)
            Art.cache[key] = nil
        end
    end

    while true do
        local count, oldestKey, oldestFrame = 0, nil, nil
        for key, entry in pairs(Art.cache) do
            count = count + 1
            if entry.frame < previous and (not oldestFrame or entry.frame < oldestFrame) then
                oldestKey, oldestFrame = key, entry.frame
            end
        end
        if count <= CFG.artworkCache or not oldestKey then break end
        pcall(imgui.ReleaseTexture, Art.cache[oldestKey].tex)
        Art.cache[oldestKey] = nil
    end
end

function Art.releaseAll()
    for key, entry in pairs(Art.cache) do
        pcall(imgui.ReleaseTexture, entry.tex)
        Art.cache[key] = nil
    end
end

local BASS_POS_BYTE = 0

function Audio.init()
    Audio.available = Runtime.hasAudio
    Audio.ffiBass = nil
    Audio.ffiTrusted = false

    if not Audio.available then
        Log.error('BASS tidak tersedia di perangkat ini; playback dinonaktifkan.')
        return
    end

    local ok = pcall(function()
        ffi.cdef [[
            uint64_t BASS_ChannelGetPosition(uint32_t handle, uint32_t mode);
            uint64_t BASS_ChannelGetLength(uint32_t handle, uint32_t mode);
            double   BASS_ChannelBytes2Seconds(uint32_t handle, uint64_t pos);
            int      BASS_ErrorGetCode(void);
            uint32_t BASS_Update(uint32_t length);
        ]]
    end)
    if not ok then
        Log.error('FFI tidak bisa disiapkan; posisi akan diestimasi.')
        return
    end

    -- LuaJIT hanya menyediakan ffi.load untuk membuka pustaka.
    local okBass, bass = pcall(ffi.load, 'libbass.so')
    if okBass and bass then
        Audio.ffiBass = bass
    else
        Log.once('bass-load', 'libbass.so tidak bisa dimuat; posisi akan diestimasi.')
    end
end

local function bassHandle(stream)
    if not stream or type(monet_get_audiostream_handle) ~= 'function' then return nil end
    local ok, handle = pcall(monet_get_audiostream_handle, stream)
    if ok and handle then return handle end
    return nil
end

--- Buka stream audio. Path lokal atau URL HTTP/HTTPS.
--- Mengembalikan nil bila berkas tidak bisa dibuka.
function Audio.open(path)
    if not Audio.available then return nil end
    local ok, stream = pcall(loadAudioStream, path)
    if not ok or not stream then return nil end

    -- Handle 0 berarti BASS gagal membuka sumber.
    local handle = bassHandle(stream)
    if handle == 0 then
        pcall(releaseAudioStream, stream)
        return nil
    end
    return stream
end

function Audio.close(stream)
    if not stream then return end
    pcall(releaseAudioStream, stream)
end

function Audio.length(stream)
    if not stream then return 0 end
    local ok, length = pcall(getAudioStreamLength, stream)
    if not ok or not length or length < 0 then return 0 end
    return length
end

--- 'playing' | 'paused' | 'stopped'
function Audio.state(stream)
    if not stream then return 'stopped' end
    local ok, state = pcall(getAudioStreamState, stream)
    if not ok or not state then return 'stopped' end
    if state == 1 then return 'playing' end
    if state == 2 then return 'paused' end
    return 'stopped'
end

function Audio.play(stream)
    if not stream then return end
    pcall(setAudioStreamState, stream, 1)     -- PLAY
end

function Audio.pause(stream)
    if not stream then return end
    pcall(setAudioStreamState, stream, 2)     -- PAUSE
end

function Audio.resume(stream)
    if not stream then return end
    pcall(setAudioStreamState, stream, 3)     -- RESUME
end

function Audio.stop(stream)
    if not stream then return end
    pcall(setAudioStreamState, stream, 0)     -- STOP
end

function Audio.setVolume(stream, volume)
    if not stream then return end
    pcall(setAudioStreamVolume, stream, volume)
end

function Audio.seek(stream, seconds)
    if not stream or seconds < 0 then return end
    pcall(setAudioStreamPosition, stream, seconds)
end

--- Posisi playback dalam detik.
function Audio.position(stream)
    if not stream then return 0 end

    local bass = Audio.ffiBass
    local handle = bassHandle(stream)
    if bass and handle then
        local ok, seconds = pcall(function()
            local bytes = bass.BASS_ChannelGetPosition(handle, BASS_POS_BYTE)
            if bytes == 0 then return 0 end
            return bass.BASS_ChannelBytes2Seconds(handle, bytes)
        end)
        if ok and seconds and seconds >= 0 then return seconds end
    end

    return 0
end

--- Bandingkan panjang dari FFI dengan panjang dari API loader.
--- Kalau cocok, jalur FFI dipercaya untuk posisi.
function Audio.verifyFfi(stream)
    if not Audio.ffiBass or Audio.ffiTrusted then return end
    local handle = bassHandle(stream)
    if not handle then return end

    local ok, ffiLength = pcall(function()
        local bytes = Audio.ffiBass.BASS_ChannelGetLength(handle, BASS_POS_BYTE)
        if bytes == 0 then return 0 end
        return Audio.ffiBass.BASS_ChannelBytes2Seconds(handle, bytes)
    end)

    if not ok or not ffiLength or ffiLength <= 0 then return end

    local loaderLength = Audio.length(stream)
    if loaderLength > 0 and math.abs(ffiLength - loaderLength) < 1.0 then
        Audio.ffiTrusted = true
        Log.info('posisi FFI tervalidasi (panjang %.1f dtk).', ffiLength)
    end
end

--- Pompa data stream BASS (wajib untuk streaming URL).
function Audio.update()
    if not Audio.ffiBass then return end
    pcall(function() Audio.ffiBass.BASS_Update(0) end)
end

function Audio.lastError()
    if not Audio.ffiBass then return nil end
    local ok, code = pcall(function() return Audio.ffiBass.BASS_ErrorGetCode() end)
    if not ok or not code or code == 0 then return nil end
    return code
end

function Player.init()
    Player.current   = nil
    Player.stream    = nil
    Player.status    = 'stopped'
    Player.position  = 0
    Player.duration  = 0
    Player.volume    = CFG.defaultVolume
    Player.muted     = false
    Player.shuffle   = false
    Player.repeatMode = 'all'
    Player.started   = false
    Player.anchorMs  = 0
    Player.anchorPos = 0
    Player.startedAt = 0
end

function Player.effectiveVolume()
    if Player.muted then return 0 end
    return Player.volume
end

--- Buka dan putar sebuah lagu. Mengembalikan true bila berhasil.
function Player.play(track)
    if not track or not track.path then return false end

    Player.closeStream()

    local stream = Audio.open(track.path)
    if not stream then
        Log.error('gagal membuka: %s', track.path)
        return false
    end

    Audio.verifyFfi(stream)
    Audio.setVolume(stream, Player.effectiveVolume())
    Audio.play(stream)

    Player.stream   = stream
    Player.current  = track
    Player.duration = Audio.length(stream)
    Player.position = 0
    Player.status   = 'playing'
    Player.started  = true
    Player.anchorMs = Runtime.nowMs()
    Player.anchorPos = 0
    Player.startedAt = Runtime.nowMs()

    return true
end

function Player.closeStream()
    if Player.stream then
        Audio.stop(Player.stream)
        Audio.close(Player.stream)
        Player.stream = nil
    end
    Player.started = false
    Player.status  = 'stopped'
    Player.position = 0
    Player.anchorMs = 0
    Player.anchorPos = 0
    Player.startedAt = 0
end

function Player.toggle()
    if not Player.stream then
        if Player.current then Player.play(Player.current) end
        return
    end
    if Player.status == 'playing' then
        Audio.pause(Player.stream)
        Player.status = 'paused'
    else
        Audio.resume(Player.stream)
        Player.status = 'playing'
        Player.anchorMs = Runtime.nowMs()
    end
end

function Player.setVolume(volume)
    Player.volume = math.max(0, math.min(1, volume))
    if Player.stream then Audio.setVolume(Player.stream, Player.effectiveVolume()) end
end

function Player.toggleMute()
    Player.muted = not Player.muted
    if Player.stream then Audio.setVolume(Player.stream, Player.effectiveVolume()) end
end

function Player.seekTo(seconds)
    if not Player.stream or Player.duration <= 0 then return end
    seconds = math.max(0, math.min(Player.duration, seconds))
    Audio.seek(Player.stream, seconds)
    Player.position = seconds
    Player.anchorMs = Runtime.nowMs()
    Player.anchorPos = seconds
end

function Player.cycleRepeat()
    local order = { 'off', 'one', 'all' }
    local index = 1
    for i, mode in ipairs(order) do
        if mode == Player.repeatMode then index = i end
    end
    Player.repeatMode = order[(index % #order) + 1]
end

function Player.toggleShuffle()
    Player.shuffle = not Player.shuffle
end

--- Hitung posisi; pakai FFI BASS bila teverifikasi, else estimasi jam.
function Player.currentPosition()
    if Player.status ~= 'playing' then return Player.position end

    if Audio.ffiBass and Audio.ffiTrusted then
        local position = Audio.position(Player.stream)
        if position > 0 then
            Player.position = position
            return position
        end
    end

    local elapsed = (Runtime.nowMs() - Player.anchorMs) / 1000
    Player.position = math.min(Player.duration, Player.anchorPos + elapsed)
    return Player.position
end

--- Dipanggil tiap frame: pantau status dan deteksi lagu selesai.
function Player.tick()
    if not Player.stream then return end

    local state = Audio.state(Player.stream)
    if state == 'playing' then
        Player.status = 'playing'
        Player.currentPosition()

        -- Stream yang tidak pernah punya durasi dan tidak maju dianggap gagal.
        if Player.duration <= 0 and Player.startedAt > 0 then
            local waited = (Runtime.nowMs() - Player.startedAt) / 1000
            if waited > CFG.urlTimeout then
                Log.once('url-timeout', 'stream URL tidak dimulai (kode bass %s)',
                    tostring(Audio.lastError()))
                Ui.message('stream URL gagal dibuka')
                Player.closeStream()
            end
        end
    elseif state == 'paused' then
        Player.status = 'paused'
    elseif Player.started then
        Player.started = false
        Player.status = 'stopped'
        Player.onTrackEnd()
    end
end

--- Lagu selesai: ulangi, lanjutkan antrean, atau berhenti.
function Player.onTrackEnd()
    if Player.repeatMode == 'one' and Player.current then
        Player.seekTo(0)
        Audio.play(Player.stream)
        Player.status = 'playing'
        Player.started = true
        Player.startedAt = Runtime.nowMs()
        Player.anchorMs = Runtime.nowMs()
        Player.anchorPos = 0
        return
    end

    local next = Queue.nextTrack()
    if next then
        Player.play(next)
    else
        Player.closeStream()
    end
end

function Queue.init()
    Queue.items = {}
    Queue.index  = nil
end

--- Masukkan lagu ke akhir antrean dan jadikan lagu itu yang sedang diputar.
--- Mengembalikan posisi lagu di antrean.
function Queue.add(track)
    Queue.items[#Queue.items + 1] = track
    Queue.index = #Queue.items
    return Queue.index
end

function Queue.addNext(track)
    local at = (Queue.index or #Queue.items) + 1
    table.insert(Queue.items, at, track)
    if Queue.index == nil then Queue.index = at end
end

--- Pindahkan lagu yang ada di antrean ke posisi setelah lagu yang sedang diputar.
function Queue.playNext(position)
    local track = Queue.items[position]
    if not track then return end

    table.remove(Queue.items, position)
    if Queue.index and position < Queue.index then Queue.index = Queue.index - 1 end
    table.insert(Queue.items, (Queue.index or 0) + 1, track)
end

function Queue.removeAt(position)
    local item = table.remove(Queue.items, position)
    if Queue.index and position < Queue.index then Queue.index = Queue.index - 1 end
    if Queue.index and Queue.index > #Queue.items then Queue.index = #Queue.items end
    if #Queue.items == 0 then Queue.index = nil end
    return item
end

function Queue.clear()
    Queue.items = {}
    Queue.index  = nil
end

function Queue.moveUp(position)
    if position <= 1 then return end
    Queue.items[position - 1], Queue.items[position] =
        Queue.items[position], Queue.items[position - 1]
    if Queue.index == position then Queue.index = position - 1
    elseif Queue.index == position - 1 then Queue.index = position end
end

function Queue.moveDown(position)
    if position >= #Queue.items then return end
    Queue.items[position + 1], Queue.items[position] =
        Queue.items[position], Queue.items[position + 1]
    if Queue.index == position then Queue.index = position + 1
    elseif Queue.index == position + 1 then Queue.index = position end
end

function Queue.shuffleOrder()
    for i = #Queue.items, 2, -1 do
        local j = math.random(i)
        Queue.items[i], Queue.items[j] = Queue.items[j], Queue.items[i]
    end
end

--- Lagu berikutnya sesuai mode shuffle & repeat.
function Queue.nextTrack()
    if #Queue.items == 0 then return nil end

    if Player.shuffle then
        if #Queue.items == 1 then return Queue.items[1] end
        local pick = math.random(#Queue.items)
        if Queue.index and pick == Queue.index then
            pick = pick % #Queue.items + 1
        end
        Queue.index = pick
        return Queue.items[pick]
    end

    local at = (Queue.index or 0) + 1
    if at > #Queue.items then
        if Player.repeatMode ~= 'all' then return nil end
        at = 1
    end
    Queue.index = at
    return Queue.items[at]
end

--- Lagu sebelumnya sesuai mode shuffle & repeat.
function Queue.previousTrack()
    if #Queue.items == 0 then return nil end

    if Player.shuffle then
        local pick = math.random(#Queue.items)
        Queue.index = pick
        return Queue.items[pick]
    end

    local at = (Queue.index or 1) - 1
    if at < 1 then
        if Player.repeatMode ~= 'all' then return nil end
        at = #Queue.items
    end
    Queue.index = at
    return Queue.items[at]
end

function Library.init()
    Library.tracks = {}
    Library.pending = {}
    Library.cursor  = 0
    Library.state   = 'idle'
    Library.error   = nil
end

function Library.startScan()
    Library.tracks = {}
    Library.pending = Fs.listAudioFiles(Fs.musicDir)
    Library.cursor  = 0
    Library.state   = 'scanning'
    Library.error   = nil
    Ui.message('memindai %d berkas...', #Library.pending)
end

local function sortTracks()
    table.sort(Library.tracks, function(a, b)
        local artistA = (a.artist or ''):lower()
        local artistB = (b.artist or ''):lower()
        if artistA ~= artistB then return artistA < artistB end
        return (a.title or ''):lower() < (b.title or ''):lower()
    end)
end

function Library.tick()
    if Library.state ~= 'scanning' then return end

    local processed = 0
    while processed < CFG.scanBudget and Library.cursor < #Library.pending do
        Library.cursor = Library.cursor + 1
        processed = processed + 1

        local entry = Library.pending[Library.cursor]
        local ok, meta = pcall(Meta.read, entry.path, entry.size)
        if ok and meta then
            Library.tracks[#Library.tracks + 1] = {
                path     = entry.path,
                name     = entry.name,
                size     = entry.size,
                title    = meta.title or entry.name,
                artist   = meta.artist,
                album    = meta.album,
                duration = meta.duration,
                artwork  = meta.artwork,
            }
        else
            Log.once('meta-' .. entry.path, 'metadata gagal dibaca: %s', entry.path)
        end
    end

    if Library.cursor >= #Library.pending then
        Library.state = 'ready'
        sortTracks()
        Ui.message('pustaka siap: %d lagu', #Library.tracks)
    end
end

--- Daftar lagu yang cocok dengan pencarian.
function Library.search(query)
    local needle = (query or ''):lower():gsub('^%s+', ''):gsub('%s+$', '')
    if needle == '' then return Library.tracks end

    local found = {}
    for _, track in ipairs(Library.tracks) do
        local haystack = ((track.title or '') .. ' ' .. (track.artist or '')
            .. ' ' .. (track.album or '')):lower()
        if haystack:find(needle, 1, true) then found[#found + 1] = track end
    end
    return found
end

function Links.isYoutube(url)
    return url:find('youtu%.be/') ~= nil
        or url:find('youtube%.com/watch') ~= nil
        or url:find('youtube%.com/playlist') ~= nil
        or url:find('youtube%.com/shorts') ~= nil
        or url:find('m%.youtube%.com/') ~= nil
end

function Links.isDirectAudio(url)
    return url:find('^https?://') ~= nil and not Links.isYoutube(url)
end

--- Buka tautan di aplikasi luar (YouTube / browser).
function Links.openExternal(url)
    if Links.tryGameOpenLink(url) then return true end
    return Links.tryClipboard(url)
end

--- Panggil OS_ServiceOpenLink dari libGTASA.
--- Offset dari dump simbol libGTASA.so build SENA Samp (arm64-v8a).
local OS_SERVICE_OPENLINK_OFFSET = 0x3221bc

function Links.tryGameOpenLink(url)
    if type(MONET_GTASA_BASE) ~= 'number' or MONET_GTASA_BASE == 0 then
        return false
    end

    local ok = pcall(function()
        pcall(ffi.cdef, [[ void OS_ServiceOpenLink(const char* url); ]])

        local gta = ffi.load('libGTASA.so')
        local exported = gta.OS_ServiceOpenLink
        if exported then
            exported(url)
            return
        end

        -- Symbol tidak diekspor: panggil langsung lewat alamat base + offset.
        local address = ffi.cast('void(*)(const char*)',
            ffi.cast('uintptr_t', MONET_GTASA_BASE) + OS_SERVICE_OPENLINK_OFFSET)
        address(url)
    end)

    if not ok then
        Log.once('openlink', 'OS_ServiceOpenLink gagal; tautan disalin ke clipboard.')
        return false
    end
    return true
end

function Links.tryClipboard(url)
    local copied = pcall(setClipboardText, url)
    if copied then
        Ui.message('tautan disalin ke clipboard')
        return true
    end
    return false
end

function Ui.init()
    -- The window opens with the /music command, like the compass and the
    -- tracer. A script that opens a window by itself gets in the way.
    Ui.open      = false
    Ui.minimized = false
    Ui.page      = 'player'
    Ui.search    = ''
    Ui.url       = ''
    Ui.messageText = ''
    Ui.messageUntil = 0
end

function Ui.message(fmt, ...)
    Ui.messageText = string.format(fmt, ...)
    Ui.messageUntil = Runtime.nowMs() + CFG.messageTime * 1000
end

function Ui.hasMessage()
    return Ui.messageText ~= '' and Runtime.nowMs() < Ui.messageUntil
end

--- IM_COL32 packing: alpha, biru, hijau, merah.
local function rgba(r, g, b, a)
    return ((a or 255) * 16777216) + (b * 65536) + (g * 256) + r
end

-- Netral sebagai dasar; merah hanya untuk interaksi dan fokus.
local PALETTE = {
    bg         = rgba(15, 15, 16),
    surface    = rgba(26, 26, 30),
    surfaceHi  = rgba(36, 36, 42),
    border     = rgba(42, 42, 46),
    text       = rgba(242, 242, 242),
    textDim    = rgba(160, 160, 160),
    accent     = rgba(225, 6, 0),
    accentDark = rgba(139, 12, 12),
    ok         = rgba(86, 182, 128),
    warn       = rgba(232, 168, 74),
}

local styleColors = 0
local styleVars  = 0

-- Hanya dorongan tema yang dihitung. Dorongan pasangan lokal (ChildBg, tab,
-- baris daftar) sudah dilepas di tempatnya; kalau ikut dihitung, popTheme
-- melepas lebih banyak dari yang didorong dan tumpukan warna ImGui kurang.
local function pushColor(index, color)
    imgui.PushStyleColorU32(index, color)
end

local function pushVarFloat(index, value)
    imgui.PushStyleVarFloat(index, value)
end

local function pushVarVec2(index, x, y)
    imgui.PushStyleVarVec2(index, imgui.ImVec2(x, y))
end

local function pushThemeColor(index, color)
    pushColor(index, color)
    styleColors = styleColors + 1
end

local function pushThemeVarFloat(index, value)
    pushVarFloat(index, value)
    styleVars = styleVars + 1
end

local function pushThemeVarVec2(index, x, y)
    pushVarVec2(index, x, y)
    styleVars = styleVars + 1
end

local function pushTheme()
    styleColors, styleVars = 0, 0
    pushThemeColor(imgui.Col.WindowBg, PALETTE.bg)
    pushThemeColor(imgui.Col.TitleBg, PALETTE.accentDark)
    pushThemeColor(imgui.Col.TitleBgActive, PALETTE.accentDark)
    pushThemeColor(imgui.Col.TitleBgCollapsed, PALETTE.accentDark)
    pushThemeColor(imgui.Col.ChildBg, PALETTE.surface)
    pushThemeColor(imgui.Col.Border, PALETTE.border)
    pushThemeColor(imgui.Col.Text, PALETTE.text)
    pushThemeColor(imgui.Col.TextDisabled, PALETTE.textDim)
    pushThemeColor(imgui.Col.FrameBg, PALETTE.surfaceHi)
    pushThemeColor(imgui.Col.FrameBgHovered, PALETTE.border)
    pushThemeColor(imgui.Col.FrameBgActive, PALETTE.accentDark)
    pushThemeColor(imgui.Col.Button, PALETTE.surfaceHi)
    pushThemeColor(imgui.Col.ButtonHovered, PALETTE.accentDark)
    pushThemeColor(imgui.Col.ButtonActive, PALETTE.accent)
    pushThemeColor(imgui.Col.SliderGrab, PALETTE.accent)
    pushThemeColor(imgui.Col.SliderGrabActive, PALETTE.accent)
    pushThemeColor(imgui.Col.Header, PALETTE.surfaceHi)
    pushThemeColor(imgui.Col.HeaderHovered, PALETTE.border)
    pushThemeColor(imgui.Col.HeaderActive, PALETTE.accentDark)
    pushThemeColor(imgui.Col.Separator, PALETTE.border)
    pushThemeColor(imgui.Col.ScrollbarBg, PALETTE.bg)
    pushThemeColor(imgui.Col.ScrollbarGrab, PALETTE.surfaceHi)
    pushThemeColor(imgui.Col.PlotHistogram, PALETTE.accent)

    local S = Runtime.scale()
    pushThemeVarFloat(imgui.StyleVar.WindowRounding, 10 * S)
    pushThemeVarFloat(imgui.StyleVar.ChildRounding, 8 * S)
    pushThemeVarFloat(imgui.StyleVar.FrameRounding, 6 * S)
    pushThemeVarFloat(imgui.StyleVar.GrabRounding, 6 * S)
    pushThemeVarFloat(imgui.StyleVar.ScrollbarSize, 8 * S)
    pushThemeVarVec2(imgui.StyleVar.WindowPadding, 12 * S, 12 * S)
    pushThemeVarVec2(imgui.StyleVar.FramePadding, 8 * S, 5 * S)
    pushThemeVarVec2(imgui.StyleVar.ItemSpacing, 8 * S, 7 * S)
end

local function popTheme()
    imgui.PopStyleColor(styleColors)
    imgui.PopStyleVar(styleVars)
    styleColors, styleVars = 0, 0
end

local function drawMusicNote(dl, x, y, size, color)
    local stem = math.max(1, size * 0.11)
    local head = size * 0.25
    dl:AddRectFilled(imgui.ImVec2(x + size * 0.30, y + size * 0.10),
        imgui.ImVec2(x + size * 0.30 + stem, y + size * 0.72), color, 0)
    dl:AddRectFilled(imgui.ImVec2(x + size * 0.60, y + size * 0.02),
        imgui.ImVec2(x + size * 0.60 + stem, y + size * 0.64), color, 0)
    dl:AddRectFilled(imgui.ImVec2(x + size * 0.30, y + size * 0.04),
        imgui.ImVec2(x + size * 0.60 + stem, y + size * 0.04 + stem), color, 0)
    dl:AddCircleFilled(imgui.ImVec2(x + size * 0.30 - head * 0.5, y + size * 0.72),
        head, color, 0)
    dl:AddCircleFilled(imgui.ImVec2(x + size * 0.60 - head * 0.5, y + size * 0.64),
        head, color, 0)
end

local function drawPlayTriangle(dl, x, y, size, color)
    dl:AddTriangleFilled(
        imgui.ImVec2(x, y),
        imgui.ImVec2(x, y + size),
        imgui.ImVec2(x + size * 0.92, y + size * 0.5),
        color)
end

local function drawPauseBars(dl, x, y, size, color)
    local bar = size * 0.26
    dl:AddRectFilled(imgui.ImVec2(x + size * 0.12, y),
        imgui.ImVec2(x + size * 0.12 + bar, y + size), color, 2)
    dl:AddRectFilled(imgui.ImVec2(x + size * 0.60, y),
        imgui.ImVec2(x + size * 0.60 + bar, y + size), color, 2)
end

local function drawStepIcon(dl, x, y, size, color, direction)
    local bar = size * 0.18
    local offset = size * 0.30
    if direction < 0 then
        dl:AddRectFilled(imgui.ImVec2(x, y), imgui.ImVec2(x + bar, y + size), color, 1)
        dl:AddTriangleFilled(
            imgui.ImVec2(x + offset, y),
            imgui.ImVec2(x + offset, y + size),
            imgui.ImVec2(x + size * 0.95, y + size * 0.5),
            color)
    else
        dl:AddRectFilled(imgui.ImVec2(x + size - bar, y),
            imgui.ImVec2(x + size, y + size), color, 1)
        dl:AddTriangleFilled(
            imgui.ImVec2(x, y + size * 0.5),
            imgui.ImVec2(x + size * 0.62, y),
            imgui.ImVec2(x + size * 0.62, y + size),
            color)
    end
end

local function drawShuffleIcon(dl, x, y, size, color)
    local t = math.max(1, size * 0.10)
    dl:AddLine(imgui.ImVec2(x, y + size * 0.18),
        imgui.ImVec2(x + size * 0.45, y + size * 0.5), color, t)
    dl:AddLine(imgui.ImVec2(x + size * 0.45, y + size * 0.5),
        imgui.ImVec2(x + size, y + size * 0.82), color, t)
    dl:AddLine(imgui.ImVec2(x, y + size * 0.82),
        imgui.ImVec2(x + size * 0.45, y + size * 0.5), color, t)
    dl:AddLine(imgui.ImVec2(x + size * 0.45, y + size * 0.5),
        imgui.ImVec2(x + size, y + size * 0.18), color, t)
    dl:AddCircleFilled(imgui.ImVec2(x + size, y + size * 0.14), size * 0.10, color, 0)
    dl:AddCircleFilled(imgui.ImVec2(x + size, y + size * 0.86), size * 0.10, color, 0)
end

local function drawRepeatIcon(dl, x, y, size, color)
    local t = math.max(1, size * 0.10)
    dl:AddLine(imgui.ImVec2(x, y + size * 0.30),
        imgui.ImVec2(x + size * 0.25, y + size * 0.12), color, t)
    dl:AddLine(imgui.ImVec2(x + size * 0.25, y + size * 0.12),
        imgui.ImVec2(x + size, y + size * 0.12), color, t)
    dl:AddLine(imgui.ImVec2(x + size, y + size * 0.70),
        imgui.ImVec2(x + size * 0.75, y + size * 0.88), color, t)
    dl:AddLine(imgui.ImVec2(x + size * 0.75, y + size * 0.88),
        imgui.ImVec2(x, y + size * 0.88), color, t)
    dl:AddLine(imgui.ImVec2(x + size, y + size * 0.12),
        imgui.ImVec2(x + size, y + size * 0.42), color, t)
    dl:AddLine(imgui.ImVec2(x + size, y + size * 0.58),
        imgui.ImVec2(x + size, y + size * 0.88), color, t)
end

local function drawInsertIcon(dl, x, y, size, color)
    local bar = size * 0.16
    dl:AddTriangleFilled(
        imgui.ImVec2(x + size * 0.06, y),
        imgui.ImVec2(x + size * 0.06, y + size),
        imgui.ImVec2(x + size * 0.62, y + size * 0.5),
        color)
    dl:AddRectFilled(imgui.ImVec2(x + size * 0.72, y),
        imgui.ImVec2(x + size * 0.72 + bar, y + size), color, 1)
end

local function drawArrowIcon(dl, x, y, size, color, up)
    local t = math.max(1, size * 0.14)
    local cx = x + size * 0.5
    if up then
        dl:AddLine(imgui.ImVec2(cx - size * 0.30, y + size * 0.62),
            imgui.ImVec2(cx, y + size * 0.32), color, t)
        dl:AddLine(imgui.ImVec2(cx, y + size * 0.32),
            imgui.ImVec2(cx + size * 0.30, y + size * 0.62), color, t)
    else
        dl:AddLine(imgui.ImVec2(cx - size * 0.30, y + size * 0.38),
            imgui.ImVec2(cx, y + size * 0.68), color, t)
        dl:AddLine(imgui.ImVec2(cx, y + size * 0.68),
            imgui.ImVec2(cx + size * 0.30, y + size * 0.38), color, t)
    end
end

local function drawCrossIcon(dl, x, y, size, color)
    local t = math.max(1, size * 0.12)
    dl:AddLine(imgui.ImVec2(x + size * 0.22, y + size * 0.22),
        imgui.ImVec2(x + size * 0.78, y + size * 0.78), color, t)
    dl:AddLine(imgui.ImVec2(x + size * 0.78, y + size * 0.22),
        imgui.ImVec2(x + size * 0.22, y + size * 0.78), color, t)
end

local function drawMinimizeIcon(dl, x, y, size, color)
    local h = math.max(1, size * 0.10)
    dl:AddRectFilled(imgui.ImVec2(x + size * 0.18, y + size * 0.46),
        imgui.ImVec2(x + size * 0.82, y + size * 0.46 + h), color, 1)
end

local function drawVolumeIcon(dl, x, y, size, color, muted)
    local t = math.max(1, size * 0.10)
    dl:AddRectFilled(imgui.ImVec2(x, y + size * 0.35),
        imgui.ImVec2(x + size * 0.22, y + size * 0.65), color, 1)
    dl:AddTriangleFilled(
        imgui.ImVec2(x + size * 0.22, y + size * 0.32),
        imgui.ImVec2(x + size * 0.22, y + size * 0.68),
        imgui.ImVec2(x + size * 0.55, y + size * 0.5),
        color)
    if muted then
        dl:AddLine(imgui.ImVec2(x + size * 0.60, y + size * 0.28),
            imgui.ImVec2(x + size * 0.95, y + size * 0.72), color, t)
    else
        dl:AddLine(imgui.ImVec2(x + size * 0.66, y + size * 0.34),
            imgui.ImVec2(x + size * 0.90, y + size * 0.5), color, t)
        dl:AddLine(imgui.ImVec2(x + size * 0.72, y + size * 0.22),
            imgui.ImVec2(x + size * 0.96, y + size * 0.5), color, t)
    end
end

local function ellipsize(text, maxWidth)
    if not text or text == '' then return '' end
    if imgui.CalcTextSize(text).x <= maxWidth then return text end
    local low, high = 0, #text
    while low < high do
        local mid = math.floor((low + high + 1) / 2)
        if imgui.CalcTextSize(text:sub(1, mid) .. '...').x <= maxWidth then
            low = mid
        else
            high = mid - 1
        end
    end
    return text:sub(1, low) .. '...'
end

local function drawLibraryIcon(dl, x, y, size, color)
    for i = 0, 2 do
        local top = y + size * (0.12 + i * 0.26)
        dl:AddRectFilled(imgui.ImVec2(x, top), imgui.ImVec2(x + size, top + size * 0.14),
            color, size * 0.07)
    end
end

local function drawQueueIcon(dl, x, y, size, color)
    for i = 0, 2 do
        local top = y + size * (0.18 + i * 0.28)
        dl:AddRectFilled(imgui.ImVec2(x, top), imgui.ImVec2(x + size * 0.22, top + size * 0.16),
            color, size * 0.05)
        dl:AddRectFilled(imgui.ImVec2(x + size * 0.34, top + size * 0.06),
            imgui.ImVec2(x + size, top + size * 0.10), color, size * 0.04)
    end
end

local function drawSettingsIcon(dl, x, y, size, color)
    for i = 0, 1 do
        local top = y + size * (0.28 + i * 0.30)
        dl:AddRectFilled(imgui.ImVec2(x, top), imgui.ImVec2(x + size, top + size * 0.10),
            color, size * 0.05)
        local knob = x + size * (0.30 + i * 0.42)
        dl:AddCircleFilled(imgui.ImVec2(knob, top + size * 0.05), size * 0.10, color, 0)
    end
end

local function drawInfoIcon(dl, x, y, size, color)
    dl:AddCircle(imgui.ImVec2(x + size * 0.5, y + size * 0.5), size * 0.42, color, 0, size * 0.10)
    dl:AddRectFilled(imgui.ImVec2(x + size * 0.45, y + size * 0.46),
        imgui.ImVec2(x + size * 0.55, y + size * 0.74), color, size * 0.05)
    dl:AddCircleFilled(imgui.ImVec2(x + size * 0.5, y + size * 0.30), size * 0.06, color, 0)
end

local function textAt(dl, x, y, text, color)
    if not text or text == '' then return end
    dl:AddText(imgui.ImVec2(x, y), color, text)
end

-- Tinggi satu baris teks, diambil dari font frame ini. Jarak antar baris yang
-- dipatok (mis. 20 px) numpuk kalau font atau skala berubah.
local function lineHeight()
    return imgui.GetFontSize() + 4.0 * Runtime.scale()
end

local function formatTime(seconds)
    if not seconds or seconds < 0 then return '--:--' end
    seconds = math.floor(seconds)
    return string.format('%d:%02d', math.floor(seconds / 60), seconds % 60)
end

local function formatDuration(seconds)
    if not seconds or seconds <= 0 then return '--:--' end
    return formatTime(seconds)
end

--- Tombol dengan ikon vektor.
--- filled = true memberi latar, dipakai untuk tombol utama (play).
local function iconButton(id, size, drawIcon, active, filled, disabled)
    local S = Runtime.scale()
    local box = size * S

    local pressed = imgui.InvisibleButton(id, imgui.ImVec2(box, box))
    local dl = imgui.GetWindowDrawList()
    local rmin, rmax = imgui.GetItemRectMin(), imgui.GetItemRectMax()
    local hovered = imgui.IsItemHovered()

    if disabled then
        pressed = false
        hovered = false
    elseif filled or hovered then
        dl:AddRectFilled(rmin, rmax, PALETTE.surfaceHi, 8 * S)
    end

    local color = PALETTE.textDim
    if active then color = PALETTE.accent end
    if hovered and not active then color = PALETTE.text end
    if disabled then color = PALETTE.border end

    local iconSize = box * 0.58
    drawIcon(dl, rmin.x + (box - iconSize) / 2, rmin.y + (box - iconSize) / 2, iconSize, color)
    return pressed
end

--- Panel "seek" yang bisa diklik dan digeser.
--- Seret ditangani manual karena ImGui di loader tidak mengekspos IsItemActive.
local function drawSeekBar()
    local S = Runtime.scale()
    local width = imgui.GetContentRegionAvail().x
    local height = 16 * S
    local origin = imgui.GetCursorScreenPos()

    local io = imgui.GetIO()
    local mouseDown = io.MouseDown[0]
    local pressed = imgui.InvisibleButton('##seek', imgui.ImVec2(width, height))
    local hovered = imgui.IsItemHovered()

    if pressed then Gui.seeking = true end
    if Gui.seeking and not mouseDown then Gui.seeking = false end

    local fraction = 0
    if Player.duration > 0 then
        if Gui.seeking and mouseDown then
            fraction = (io.MousePos.x - origin.x) / math.max(width, 1)
            fraction = math.max(0, math.min(1, fraction))
            Player.seekTo(fraction * Player.duration)
        else
            fraction = math.max(0, math.min(1, Player.position / Player.duration))
        end
    end

    local dl = imgui.GetWindowDrawList()
    dl:AddRectFilled(origin, imgui.ImVec2(origin.x + width, origin.y + height),
        PALETTE.surfaceHi, 4 * S)
    local filled = width * fraction
    if filled > 0 then
        dl:AddRectFilled(origin, imgui.ImVec2(origin.x + filled, origin.y + height),
            PALETTE.accent, 4 * S)
    end
    dl:AddCircleFilled(imgui.ImVec2(origin.x + filled, origin.y + height / 2),
        5 * S, hovered and PALETTE.text or PALETTE.accent, 0)
end

--- Kotak artwork pada koordinat tertentu: texture bila ada, kalau tidak
--- gambar cadangan. Digambar lewat draw list supaya bisa menumpuk di atas
--- tombol transparan.
local function drawArtwork(dl, track, x, y, size)
    local S = Runtime.scale()
    local texture = Art.textureFor(track)
    local rmin = imgui.ImVec2(x, y)
    local rmax = imgui.ImVec2(x + size, y + size)

    if texture then
        dl:AddImage(texture, rmin, rmax)
        return
    end

    dl:AddRectFilled(rmin, rmax, PALETTE.surfaceHi, 8 * S)
    drawMusicNote(dl, x + size * 0.30, y + size * 0.28, size * 0.40, PALETTE.accent)
end

-- --- bagian-bagian GUI --------------------------------------------------

--- Baris status: keadaan pemutar di kiri, tombol minimize & tutup di kanan.
--- Judul jendela sudah ada di title bar, jadi tidak diulang di sini.
local PAGES = {
    { key = 'player',   label = 'Player',   icon = drawMusicNote },
    { key = 'library',  label = 'Library',  icon = drawLibraryIcon },
    { key = 'queue',    label = 'Queue',    icon = drawQueueIcon },
    { key = 'settings', label = 'Settings', icon = drawSettingsIcon },
    { key = 'about',    label = 'About',    icon = drawInfoIcon },
}

local function drawHeader()
    local S = Runtime.scale()
    local dl = imgui.GetWindowDrawList()
    local rowY = imgui.GetCursorPosY()
    local leftX = imgui.GetCursorPosX()
    local rightX = leftX + imgui.GetContentRegionAvail().x
    local icon = 22

    drawMusicNote(dl, leftX, rowY + 2 * S, icon * 0.80 * S, PALETTE.accent)
    local titleX = leftX + icon * S + 10 * S
    textAt(dl, titleX, rowY + 3 * S, 'SAMP', PALETTE.text)
    textAt(dl, titleX + imgui.CalcTextSize('SAMP ').x, rowY + 3 * S, 'MUSIC', PALETTE.accent)

    imgui.SetCursorPos(imgui.ImVec2(rightX - icon * S, rowY))
    local closePressed = iconButton('##close', icon, drawCrossIcon, false, false)

    imgui.SetCursorPos(imgui.ImVec2(rightX - icon * S * 2 - 8 * S, rowY))
    local minimizePressed = iconButton('##minimize', icon, drawMinimizeIcon, false, false)

    local lineY = rowY + icon * S + 6 * S
    dl:AddRectFilled(imgui.ImVec2(leftX, lineY), imgui.ImVec2(rightX, lineY + 2 * S),
        PALETTE.accent)

    if minimizePressed then Ui.minimized = not Ui.minimized end
    if closePressed then Ui.open = false end

    imgui.SetCursorPos(imgui.ImVec2(leftX, lineY + 2 * S))
end

local function drawSidebar()
    local S = Runtime.scale()
    local width = imgui.GetContentRegionAvail().x
    local rowH = 38 * S
    local iconSize = 16 * S

    for _, page in ipairs(PAGES) do
        local pressed = imgui.InvisibleButton('##nav_' .. page.key,
            imgui.ImVec2(width, rowH))
        local rmin, rmax = imgui.GetItemRectMin(), imgui.GetItemRectMax()
        local dl = imgui.GetWindowDrawList()
        local active = (Ui.page == page.key)

        if active then
            dl:AddRectFilled(rmin, rmax, PALETTE.accentDark, 8 * S)
            dl:AddRectFilled(imgui.ImVec2(rmin.x, rmin.y + 6 * S),
                imgui.ImVec2(rmin.x + 3 * S, rmax.y - 6 * S), PALETTE.accent)
        elseif imgui.IsItemHovered() then
            dl:AddRectFilled(rmin, rmax, PALETTE.surfaceHi, 8 * S)
        end

        page.icon(dl, rmin.x + 12 * S, rmin.y + (rowH - iconSize) * 0.5, iconSize,
            active and PALETTE.accent or PALETTE.textDim)
        textAt(dl, rmin.x + 12 * S + iconSize + 10 * S,
            rmin.y + (rowH - lineHeight()) * 0.5, page.label,
            active and PALETTE.text or PALETTE.textDim)

        if pressed then Ui.page = page.key end
    end
end

local function drawPlayerPage()
    local S = Runtime.scale()
    local track = Player.current
    local art = 132 * S
    local pad = 14 * S
    local width = imgui.GetContentRegionAvail().x

    local origin = imgui.GetCursorScreenPos()
    local dl = imgui.GetWindowDrawList()

    dl:AddRectFilled(imgui.ImVec2(origin.x, origin.y),
        imgui.ImVec2(origin.x + width, origin.y + art + pad * 2), PALETTE.surface, 10 * S)

    drawArtwork(dl, track, origin.x + pad, origin.y + pad, art)

    local lh = lineHeight()
    local textX = origin.x + pad + art + 16 * S
    local textW = origin.x + width - pad - textX
    local title = track and track.title or 'Tidak ada lagu'
    local artist = track and (track.artist or '-') or 'Tekan /music untuk membuka'
    textAt(dl, textX, origin.y + pad + 4 * S, ellipsize(title, textW), PALETTE.text)
    textAt(dl, textX, origin.y + pad + 4 * S + lh, ellipsize(artist, textW), PALETTE.textDim)

    local timeText = formatTime(Player.position) .. ' / ' .. formatDuration(Player.duration)
    local timeW = imgui.CalcTextSize(timeText).x
    textAt(dl, origin.x + width - pad - timeW, origin.y + art + pad - lh, timeText,
        PALETTE.textDim)

    imgui.Dummy(imgui.ImVec2(width, art + pad * 2))

    drawSeekBar()
end

local function drawLibraryPage()
    local S = Runtime.scale()
    if not Gui.searchBuffer then
        Gui.searchBuffer = imgui.new.char[128]()
    end

    imgui.SetNextItemWidth(-92 * S)
    imgui.InputText('##search', Gui.searchBuffer, 128)
    Ui.search = ffi.string(Gui.searchBuffer)

    imgui.SameLine()
    if imgui.Button('Muat ulang', imgui.ImVec2(84 * S, 0)) then
        Library.startScan()
    end

    imgui.Separator()
    drawLibraryList()
end

local function drawQueuePage()
    local S = Runtime.scale()
    if imgui.Button('Acak', imgui.ImVec2(80 * S, 0)) then
        Queue.shuffleOrder()
    end
    imgui.SameLine()
    if imgui.Button('Kosongkan', imgui.ImVec2(90 * S, 0)) then
        Queue.clear()
        Ui.message('antrean dikosongkan')
    end

    imgui.Separator()
    drawQueueList()
end

local function drawSettingsPage()
    local S = Runtime.scale()
    local width = imgui.GetContentRegionAvail().x

    textAt(imgui.GetWindowDrawList(), imgui.GetCursorScreenPos().x,
        imgui.GetCursorScreenPos().y, 'Stream URL', PALETTE.text)
    imgui.Dummy(imgui.ImVec2(0, lineHeight() + 4 * S))

    if not Gui.urlBuffer then
        Gui.urlBuffer = imgui.new.char[256]()
    end

    imgui.SetNextItemWidth(width - 74 * S)
    local changed = imgui.InputText('##url', Gui.urlBuffer, 256,
        imgui.InputTextFlags.EnterReturnsTrue)
    Ui.url = ffi.string(Gui.urlBuffer)

    imgui.SameLine(0, 6 * S)
    if imgui.Button('Buka', imgui.ImVec2(74 * S, 0)) then
        changed = true
    end

    if changed and Ui.url ~= '' then
        local url = Ui.url:gsub('^%s+', ''):gsub('%s+$', '')
        if Links.isYoutube(url) then
            if Links.openExternal(url) then
                Ui.message('tautan YouTube dibuka di aplikasi luar')
            end
        elseif Links.isDirectAudio(url) then
            local track = { path = url, title = url:match('([^/]+)$'), isUrl = true }
            if Player.play(track) then
                Queue.add(track)
                Ui.message('memutar stream: %s', track.title)
            else
                Ui.message('gagal membuka stream URL')
            end
        else
            Ui.message('URL tidak dikenali')
        end
    end

    imgui.Separator()
    textAt(imgui.GetWindowDrawList(), imgui.GetCursorScreenPos().x,
        imgui.GetCursorScreenPos().y, 'Pustaka', PALETTE.text)
    imgui.Dummy(imgui.ImVec2(0, lineHeight() + 4 * S))

    if imgui.Button('Pindai ulang folder musik', imgui.ImVec2(180 * S, 0)) then
        Library.startScan()
    end
    imgui.SameLine(0, 6 * S)
    if imgui.Button('Bersihkan antrean', imgui.ImVec2(140 * S, 0)) then
        Queue.clear()
        Ui.message('antrean dikosongkan')
    end

    imgui.Dummy(imgui.ImVec2(0, 8 * S))
    local folder = Fs.musicDir
    local fw = imgui.CalcTextSize(folder).x
    textAt(imgui.GetWindowDrawList(), imgui.GetCursorScreenPos().x,
        imgui.GetCursorScreenPos().y, folder, PALETTE.textDim)
    imgui.Dummy(imgui.ImVec2(0, lineHeight() + 4 * S))
    local hint = 'Letakkan berkas .mp3, .wav, .ogg atau .flac di folder itu.'
    local hw = imgui.CalcTextSize(hint).x
    textAt(imgui.GetWindowDrawList(), imgui.GetCursorScreenPos().x,
        imgui.GetCursorScreenPos().y, hint, PALETTE.textDim)
    imgui.Dummy(imgui.ImVec2(0, lineHeight()))
end

local function drawAboutPage()
    local S = Runtime.scale()
    local dl = imgui.GetWindowDrawList()
    local x = imgui.GetCursorScreenPos().x
    local y = imgui.GetCursorScreenPos().y
    local lh = lineHeight() + 4 * S

    local function line(text, color)
        textAt(dl, x, y, text, color)
        y = y + lh
    end

    line('SAMP MUSIC 1.1', PALETTE.text)
    line('Sena Engine - pemutar musik untuk MonetLoader di Android', PALETTE.textDim)
    line('', PALETTE.textDim)

    line('LISENSI: GNU GPL v3', PALETTE.accent)
    line('Berkas ini perangkat lunak bebas. Anda boleh memakai, menyalin,', PALETTE.textDim)
    line('mengubah, dan mendistribusikannya, dengan syarat:', PALETTE.textDim)
    line('  1._memberitahu hak cipta dan lisensi ini ikut disertakan;', PALETTE.textDim)
    line('  2. menyatakan perubahan yang Anda buat;', PALETTE.textDim)
    line('  3. mendistribusikan ulang dengan lisensi yang sama (GPL v3).', PALETTE.textDim)
    line('', PALETTE.textDim)
    line('Jual ulang versi yang disBundel tidak boleh memakai nama "Sena"', PALETTE.textDim)
    line('atau lisensi yang lebih ketat. README lengkap ada di:', PALETTE.textDim)
    line(Fs.root .. '/sampmusic-README.md', PALETTE.textDim)
    line('Skrip ini: ' .. Fs.root .. '/sampmusic.lua', PALETTE.textDim)

    imgui.Dummy(imgui.ImVec2(0, y - imgui.GetCursorScreenPos().y + 8 * S))
end

local function drawPage()
    if Ui.page == 'player' then
        drawPlayerPage()
    elseif Ui.page == 'library' then
        drawLibraryPage()
    elseif Ui.page == 'queue' then
        drawQueuePage()
    elseif Ui.page == 'settings' then
        drawSettingsPage()
    else
        drawAboutPage()
    end
end

local function drawLibraryList()
    local S = Runtime.scale()
    local rowHeight = 44 * S
    local thumb = 34 * S

    local tracks = Library.search(Ui.search)
    if #tracks == 0 then
        local dl = imgui.GetWindowDrawList()
        local rmin = imgui.GetCursorScreenPos()
        local width = imgui.GetContentRegionAvail().x
        local emptyH = 120 * S

        dl:AddRectFilled(rmin, imgui.ImVec2(rmin.x + width, rmin.y + emptyH),
            PALETTE.surface, 10 * S)
        drawMusicNote(dl, rmin.x + width * 0.5 - 16 * S, rmin.y + 24 * S, 32 * S,
            PALETTE.textDim)

        local message = Library.state == 'scanning' and 'memindai...'
            or 'Tidak ada lagu dalam pustaka.'
        local hint = Library.state == 'scanning' and ''
            or 'Letakkan berkas musik di folder musik.'
        local mw = imgui.CalcTextSize(message).x
        textAt(dl, rmin.x + (width - mw) * 0.5, rmin.y + 72 * S, message, PALETTE.text)
        if hint ~= '' then
            local hw = imgui.CalcTextSize(hint).x
            textAt(dl, rmin.x + (width - hw) * 0.5, rmin.y + 72 * S + lineHeight(),
                hint, PALETTE.textDim)
        end

        imgui.Dummy(imgui.ImVec2(width, emptyH))
        return
    end

    for index, track in ipairs(tracks) do
        local width = imgui.GetContentRegionAvail().x
        local isCurrent = (Player.current == track)

        local pressed = imgui.InvisibleButton('##lib' .. index,
            imgui.ImVec2(width, rowHeight))
        local rmin, rmax = imgui.GetItemRectMin(), imgui.GetItemRectMax()
        local dl = imgui.GetWindowDrawList()

        if isCurrent then
            dl:AddRectFilled(rmin, rmax, PALETTE.accentDark, 6 * S)
            dl:AddRectFilled(imgui.ImVec2(rmin.x, rmin.y),
                imgui.ImVec2(rmin.x + 2 * S, rmax.y), PALETTE.accent)
        elseif imgui.IsItemHovered() then
            dl:AddRectFilled(rmin, rmax, PALETTE.surfaceHi, 6 * S)
        end

        -- artwork kecil: hanya untuk baris yang benar-benar terlihat, supaya
        -- texture tidak dibuat lalu dibuang setiap frame
        local clipMin = dl:GetClipRectMin()
        local clipMax = dl:GetClipRectMax()
        local visible = not (rmax.y < clipMin.y or rmin.y > clipMax.y)
        local texture = visible and Art.textureFor(track) or nil
        if texture then
            dl:AddImage(texture,
                imgui.ImVec2(rmin.x + 8 * S, rmin.y + 5 * S),
                imgui.ImVec2(rmin.x + 8 * S + thumb, rmin.y + 5 * S + thumb))
        else
            dl:AddRectFilled(
                imgui.ImVec2(rmin.x + 8 * S, rmin.y + 5 * S),
                imgui.ImVec2(rmin.x + 8 * S + thumb, rmin.y + 5 * S + thumb),
                PALETTE.surfaceHi, 4 * S)
            drawMusicNote(dl, rmin.x + 8 * S + thumb * 0.30, rmin.y + 5 * S + thumb * 0.26,
                thumb * 0.40, PALETTE.accent)
        end

        local textX = rmin.x + thumb + 18 * S
        local durationText = formatDuration(track.duration)
        local durationWidth = imgui.CalcTextSize(durationText).x
        local maxText = rmax.x - textX - durationWidth - 16 * S
        local lh = lineHeight()

        textAt(dl, textX, rmin.y + (rowHeight - lh * 2) * 0.5,
            ellipsize(track.title or '', maxText), PALETTE.text)
        textAt(dl, textX, rmin.y + (rowHeight - lh * 2) * 0.5 + lh,
            ellipsize(track.artist or '-', maxText), PALETTE.textDim)
        textAt(dl, rmax.x - durationWidth - 10 * S, rmin.y + (rowHeight - lh) * 0.5,
            durationText, PALETTE.textDim)

        if pressed then
            if Player.play(track) then
                Queue.add(track)
                Ui.message('memutar: %s', track.title)
            end
        end
    end
end

local function drawQueueList()
    local S = Runtime.scale()
    local rowHeight = 34 * S

    if #Queue.items == 0 then
        local dl = imgui.GetWindowDrawList()
        local rmin = imgui.GetCursorScreenPos()
        local width = imgui.GetContentRegionAvail().x
        local emptyH = 120 * S

        dl:AddRectFilled(rmin, imgui.ImVec2(rmin.x + width, rmin.y + emptyH),
            PALETTE.surface, 10 * S)
        drawMusicNote(dl, rmin.x + width * 0.5 - 16 * S, rmin.y + 24 * S, 32 * S,
            PALETTE.textDim)

        local message = 'Antrean kosong.'
        local mw = imgui.CalcTextSize(message).x
        textAt(dl, rmin.x + (width - mw) * 0.5, rmin.y + 72 * S, message, PALETTE.text)

        imgui.Dummy(imgui.ImVec2(width, emptyH))
        return
    end

    for index = 1, #Queue.items do
        local track = Queue.items[index]
        local width = imgui.GetContentRegionAvail().x
        local isCurrent = (Player.current == track)

        local pressed = imgui.InvisibleButton('##queue' .. index,
            imgui.ImVec2(width, rowHeight))
        local rmin, rmax = imgui.GetItemRectMin(), imgui.GetItemRectMax()
        local dl = imgui.GetWindowDrawList()

        if isCurrent then
            dl:AddRectFilled(rmin, rmax, PALETTE.accentDark, 6 * S)
            dl:AddRectFilled(imgui.ImVec2(rmin.x, rmin.y),
                imgui.ImVec2(rmin.x + 2 * S, rmax.y), PALETTE.accent)
        elseif imgui.IsItemHovered() then
            dl:AddRectFilled(rmin, rmax, PALETTE.surfaceHi, 6 * S)
        end

        local lh = lineHeight()
        local durationText = formatDuration(track.duration)
        local durationWidth = imgui.CalcTextSize(durationText).x
        local maxText = rmax.x - rmin.x - durationWidth - 28 * S

        textAt(dl, rmin.x + 12 * S, rmin.y + (rowHeight - lh) * 0.5,
            ellipsize(track.title or '', maxText), PALETTE.text)
        textAt(dl, rmax.x - durationWidth - 10 * S, rmin.y + (rowHeight - lh) * 0.5,
            durationText, PALETTE.textDim)

        if pressed then
            if Player.play(track) then
                Ui.message('memutar: %s', track.title)
            end
        end
    end
end

local function drawPlaybackBar()
    local S = Runtime.scale()
    local size = 24
    local gap = 8 * S
    local hasTrack = Player.current ~= nil
    local hasQueue = #Queue.items > 0

    if iconButton('##shuffle', size, drawShuffleIcon, Player.shuffle, false) then
        Player.toggleShuffle()
        Ui.message('shuffle %s', Player.shuffle and 'nyala' or 'mati')
    end

    imgui.SameLine(0, gap)
    if iconButton('##prev', size, function(d, x, y, s, color)
        drawStepIcon(d, x, y, s, color, -1)
    end, false, false, not (hasTrack or hasQueue)) then
        local previous = Queue.previousTrack()
        if previous then Player.play(previous)
        elseif Player.current then Player.seekTo(0) end
    end

    imgui.SameLine(0, gap)
    if iconButton('##play', size, function(d, x, y, s, color)
        if Player.status == 'playing' then
            drawPauseBars(d, x, y, s, color)
        else
            drawPlayTriangle(d, x, y, s, color)
        end
    end, Player.status == 'playing', true, not hasTrack) then
        Player.toggle()
    end

    imgui.SameLine(0, gap)
    if iconButton('##next', size, function(d, x, y, s, color)
        drawStepIcon(d, x, y, s, color, 1)
    end, false, false, not (hasTrack or hasQueue)) then
        local next = Queue.nextTrack()
        if next then Player.play(next) end
    end

    imgui.SameLine(0, gap)
    if iconButton('##repeat', size, drawRepeatIcon, Player.repeatMode ~= 'off', false) then
        Player.cycleRepeat()
        Ui.message('repeat: %s', Player.repeatMode)
    end

    imgui.SameLine(0, 10 * S)
    if iconButton('##mute', 20, function(d, x, y, s, color)
        drawVolumeIcon(d, x, y, s, color, Player.muted)
    end, Player.muted) then
        Player.toggleMute()
    end

    -- slider mengisi sisa baris; ImGui menulis persennya di kanan slider
    if not Gui.volumeValue then
        Gui.volumeValue = imgui.new.float(Player.volume)
    end
    Gui.volumeValue[0] = Player.volume
    local sliderW = math.max(60 * S, imgui.GetContentRegionAvail().x - 46 * S)
    imgui.SameLine(0, 6 * S)
    imgui.SetNextItemWidth(sliderW)
    if imgui.SliderFloat('##volume', Gui.volumeValue, 0.0, 1.0, '%.0f%%') then
        Player.setVolume(Gui.volumeValue[0])
    end
end

local function drawFull()
    local S = Runtime.scale()
    -- Jendela tidak boleh melebihi layar; sisa isi digulir oleh ImGui.
    local width = math.min(560 * S, Runtime.screenWidth - 16 * S)
    local height = math.min(600 * S, Runtime.screenHeight - 16 * S)

    imgui.SetNextWindowPos(
        imgui.ImVec2(Runtime.screenWidth - width - 8 * S, 8 * S),
        imgui.Cond.FirstUseEver)
    imgui.SetNextWindowSize(imgui.ImVec2(width, height), imgui.Cond.FirstUseEver)

    imgui.Begin(CFG.title, nil,
        imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoSavedSettings)

    drawHeader()

    local avail = imgui.GetContentRegionAvail()
    local sidebarW = math.min(136 * S, width * 0.32)
    local barH = 40 * S
    local contentH = math.max(140 * S, avail.y - barH - 8 * S)

    pushColor(imgui.Col.ChildBg, PALETTE.bg)
    imgui.BeginChild('##sidebar', imgui.ImVec2(sidebarW, contentH), true)
    imgui.PopStyleColor()
    drawSidebar()
    imgui.EndChild()

    imgui.SameLine(0, 8 * S)

    local mainX = imgui.GetCursorScreenPos().x
    local mainW = imgui.GetContentRegionAvail().x

    pushColor(imgui.Col.ChildBg, PALETTE.bg)
    imgui.BeginChild('##main', imgui.ImVec2(mainW, contentH), true)
    imgui.PopStyleColor()
    drawPage()
    imgui.EndChild()

    -- playback bar: satu baris di bawah area konten, lebarnya area konten
    imgui.SetCursorPosX(mainX)
    local dl = imgui.GetWindowDrawList()
    dl:AddRectFilled(
        imgui.ImVec2(mainX, imgui.GetCursorPosY() - 6 * S),
        imgui.ImVec2(mainX + mainW, imgui.GetCursorPosY() + barH), PALETTE.surface, 10 * S)
    imgui.SetCursorPosY(imgui.GetCursorPosY() + 4 * S)
    drawPlaybackBar()

    imgui.End()
end

local function drawCompact()
    local S = Runtime.scale()
    local pad = 8 * S
    local art = 48 * S
    local lh = lineHeight()
    local buttonH = 24 * S

    -- tinggi dihitung dari isinya: angka tetap membuat baris teks yang
    -- lebih besar dari 24 px menabrak baris di bawahnya
    local textBlock = math.max(art, lh * 2)
    local height = pad * 2 + textBlock + 6 * S + buttonH
    local width = math.min(260 * S, Runtime.screenWidth - 24 * S)

    imgui.SetNextWindowPos(imgui.ImVec2(Runtime.screenWidth - width - 12 * S, 40 * S),
        imgui.Cond.FirstUseEver)
    imgui.SetNextWindowSize(imgui.ImVec2(width, height), imgui.Cond.FirstUseEver)

    imgui.Begin('##sampmusic-compact', nil,
        imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoResize
        + imgui.WindowFlags.NoSavedSettings)

    local track = Player.current
    local dl = imgui.GetWindowDrawList()
    local origin = imgui.GetCursorScreenPos()

    imgui.InvisibleButton('##artwork', imgui.ImVec2(art, art))
    drawArtwork(dl, track, origin.x, origin.y, art)

    local textX = origin.x + art + 10 * S
    local maxWidth = imgui.GetContentRegionAvail().x - art - 10 * S
    local title = track and track.title or 'SAMP MUSIC'
    local artist = track and (track.artist or '-') or 'tekan /music'
    textAt(dl, textX, origin.y + 2 * S, ellipsize(title, maxWidth), PALETTE.text)
    textAt(dl, textX, origin.y + 2 * S + lh, ellipsize(artist, maxWidth), PALETTE.textDim)

    imgui.SetCursorPos(imgui.ImVec2(pad, pad + textBlock + 6 * S))
    if imgui.Button('Buka', imgui.ImVec2(-1, buttonH)) then
        Ui.minimized = false
    end

    imgui.End()
end

function Gui.draw()
    if not Ui.open then return end
    pushTheme()
    if Ui.minimized then
        drawCompact()
    else
        drawFull()
    end
    popTheme()
end

-- Loader menggambar jendela ini pada callback frame render.
-- Callback before-frame berjalan sebelum frame dimulai: di situ texture yang
-- tidak dipakai dilepas, karena draw list belum menunjuk apa pun.
imgui.OnFrame(
    function() return Ui.open end,
    function(self)
        self.HideCursor = true
        Art.frame = Art.frame + 1
        Art.collectGarbage()
    end,
    function(self) Gui.draw() end
)

local function playFromQueue()
    local track = Queue.nextTrack()
    if track then Player.play(track) end
end

local function handleCommand(argument)
    local command = (argument or ''):lower():gsub('^%s+', ''):gsub('%s+$', '')

    local pages = { player = true, library = true, queue = true,
        settings = true, about = true }
    if pages[command] then
        Ui.open = true
        Ui.minimized = false
        Ui.page = command
        return
    end

    if command == '' or command == 'open' then
        Ui.open = true
        Ui.minimized = false
    elseif command == 'close' then
        Ui.open = false
    elseif command == 'toggle' then
        Ui.open = not Ui.open
    elseif command == 'play' then
        if Player.current then Player.play(Player.current) else playFromQueue() end
    elseif command == 'pause' then
        Player.toggle()
    elseif command == 'next' then
        playFromQueue()
    elseif command == 'prev' then
        local previous = Queue.previousTrack()
        if previous then Player.play(previous) end
    elseif command == 'refresh' then
        Library.startScan()
    else
        local volume = command:match('^volume%s+(%d+)')
        if volume then
            Player.setVolume(tonumber(volume) / 100)
            Ui.message('volume: %s%%', volume)
        else
            Ui.message('perintah tidak dikenal: %s', command)
        end
    end
end

local function registerCommand()
    if type(sampRegisterChatCommand) ~= 'function' then
        Log.once('cmd', 'sampRegisterChatCommand tidak tersedia')
        return
    end
    local ok = pcall(sampRegisterChatCommand, 'music', handleCommand)
    if not ok then Log.once('cmd', 'registrasi perintah /music gagal') end
end

function main()
    Runtime.detect()
    Fs.init()
    Art.init()
    Audio.init()
    Player.init()
    Queue.init()
    Library.init()
    Ui.init()

    if not Fs.ensureMusicDir() then
        Log.error('folder musik tidak bisa dibuat: %s', Fs.musicDir)
    end

    registerCommand()
    Library.startScan()

    while true do
        Player.tick()
        Audio.update()
        Library.tick()
        wait(0)
    end
end

--- Dipanggil loader saat skrip dihentikan: hentikan audio dan lepas texture.
--- Dipanggil untuk setiap skrip, jadi cek dulu skrip mana yang berakhir.
function onScriptTerminate(terminated)
    if type(terminated) == 'table' and type(thisScript) == 'function' then
        local mine = thisScript()
        if terminated.id ~= mine.id or terminated.filename ~= mine.filename then return end
    end
    Player.closeStream()
    Art.releaseAll()
end
