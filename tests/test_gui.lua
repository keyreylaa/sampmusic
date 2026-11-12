-- Harness uji SAMP MUSIC: jalankan skrip di host dengan API mimgui dan
-- loader tiruan, lalu panggil callback frame beberapa kali. Tujuannya
-- menangkap error runtime (nilai nil, koordinat salah) tanpa perlu HP.
--
-- Pakai: luajit test_gui.lua [path skrip]

local scriptPath = arg[1] or '/sdcard/Android/media/com.senasamp.game/monetloader/sampmusic.lua'

local ffi = require 'ffi'
local function Vec2(x, y) return { x = x or 0, y = y or 0 } end

-- --- draw list tiruan ------------------------------------------------------
local dl = {}
local function addMethod(name)
    dl[name] = function() return nil end
end
for _, name in ipairs({
    'AddRectFilled', 'AddRect', 'AddText', 'AddTextFontPtr',
    'AddLine', 'AddCircle', 'AddCircleFilled', 'AddTriangleFilled', 'AddRectFilledMultiColor',
    'AddTriangle', 'AddQuad', 'AddQuadFilled', 'AddPolyline', 'AddBezierCurve',
}) do addMethod(name) end

-- AddImage / AddImageRounded diperiksa ketat: di perangkat, uv_a/uv_b/warna
-- yang nil langsung jadi "bad argument #4 to 'AddImageRounded'". Mock longgar
-- tidak akan menangkap kelas bug itu.
local function checkVec2(v, fname, argn)
    if type(v) ~= 'table' or type(v.x) ~= 'number' or type(v.y) ~= 'number' then
        error(string.format('%s: argumen #%d harus ImVec2, dapat %s',
            fname, argn, tostring(v)), 2)
    end
end

local function checkTex(tex, fname)
    if tex == nil then
        error(fname .. ': texture nil', 2)
    end
end

-- AddImage: uv_a/uv_b/warna punya nilai default di mimgui.
dl.AddImage = function(self, tex, a, b, uv_a, uv_b, col)
    checkTex(tex, 'AddImage')
    checkVec2(a, 'AddImage', 2)
    checkVec2(b, 'AddImage', 3)
    if uv_a ~= nil then checkVec2(uv_a, 'AddImage', 4) end
    if uv_b ~= nil then checkVec2(uv_b, 'AddImage', 5) end
    if col ~= nil and type(col) ~= 'number' then
        error('AddImage: argumen #6 harus angka warna', 2)
    end
end

-- AddImageRounded: uv_a/uv_b/warna/rounding TIDAK punya default.
dl.AddImageRounded = function(self, tex, a, b, uv_a, uv_b, col, rounding, rounding_corners)
    checkTex(tex, 'AddImageRounded')
    checkVec2(a, 'AddImageRounded', 2)
    checkVec2(b, 'AddImageRounded', 3)
    checkVec2(uv_a, 'AddImageRounded', 4)
    checkVec2(uv_b, 'AddImageRounded', 5)
    if type(col) ~= 'number' then
        error('AddImageRounded: argumen #6 harus angka warna', 2)
    end
    if type(rounding) ~= 'number' then
        error('AddImageRounded: argumen #7 harus angka', 2)
    end
end
dl.GetClipRectMin = function() return Vec2(0, 0) end
dl.GetClipRectMax = function() return Vec2(1600, 720) end

-- --- imgui tiruan ---------------------------------------------------------
local frame = { x = 0, y = 0, screen = Vec2(420, 40) }
local cursorX, cursorY = 0, 0
local frameCallbacks = {}

local imgui = {}
imgui.ImVec2 = function(x, y) return Vec2(x, y) end
imgui.ImVec4 = function(x, y, z, w) return { x = x, y = y, z = z, w = w } end
imgui.Col = setmetatable({}, { __index = function() return 0 end })
imgui.WindowFlags = setmetatable({}, { __index = function() return 0 end })
imgui.Cond = setmetatable({}, { __index = function() return 0 end })
imgui.InputTextFlags = setmetatable({}, { __index = function() return 0 end })
imgui.InputTextFlags.EnterReturnsTrue = 1
imgui.DrawCornerFlags_All = 0
imgui.ImDrawCornerFlags_All = 0

imgui.GetWindowDrawList = function() return dl end
-- lebar/tinggi konten berubah-ubah supaya jalurAcuan ikut teruji
local contentSize = Vec2(600, 380)
imgui.GetContentRegionAvail = function() return contentSize end
imgui.GetCursorScreenPos = function() return frame.screen end
imgui.GetCursorPosX = function() return cursorX end
imgui.GetCursorPosY = function() return cursorY end
imgui.SetCursorPos = function(v) cursorX, cursorY = v.x, v.y end
imgui.SetCursorPosX = function(x) cursorX = x end
imgui.SetCursorPosY = function(y) cursorY = y end
imgui.SetCursorScreenPos = function(v) frame.screen = v end
imgui.GetWindowPos = function() return Vec2(420, 40) end
imgui.GetWindowSize = function() return Vec2(150, 380) end
imgui.GetItemRectMin = function() return Vec2(430, 100) end
imgui.GetItemRectMax = function() return Vec2(600, 140) end
imgui.IsItemHovered = function() return false end
-- tombol yang diklik pada frame tertentu
local clickIds = {}
local clicked = {}
imgui.InvisibleButton = function(id)
    if clickIds[id] and not clicked[id] then
        clicked[id] = true
        return true
    end
    return false
end
imgui.Button = function() return false end
imgui.SameLine = function() end
imgui.NewLine = function() end
imgui.Separator = function() end
imgui.Dummy = function() end
imgui.SetNextItemWidth = function() end
imgui.InputText = function() return false end
imgui.SliderFloat = function() return false end
imgui.CalcTextSize = function(text)
    text = tostring(text or '')
    return { x = #text * 8, y = 16 }
end
imgui.GetFontSize = function() return 16 end
imgui.GetFont = function() return { ptr = true } end
imgui.SetWindowFontScale = function() end
imgui.PushFont = function() end
imgui.PopFont = function() end
imgui.TextUnformatted = function() end
imgui.Text = function() end
imgui.Begin = function() return true end
imgui.End = function() end
imgui.BeginChild = function() return true end
imgui.EndChild = function() end
imgui.SetNextWindowPos = function() end
imgui.SetNextWindowSize = function() end

-- imgui.new, implementasi sama seperti mimgui (pakai ffi asli)
local new = {}
setmetatable(new, {
    __index = function(self, key)
        local basetype = ffi.typeof(key)
        local mt = {
            __index = function(self, sz)
                return setmetatable({ type = ffi.typeof('$[$]', self.type, sz) }, getmetatable(self))
            end,
            __call = function(self, ...) return self.type(...) end,
        }
        return setmetatable({ type = ffi.typeof('$[1]', basetype), basetype = basetype }, {
            __index = function(self, sz)
                return setmetatable({ type = ffi.typeof('$[$]', self.basetype, sz) }, mt)
            end,
            __call = mt.__call,
        })
    end,
    __call = function(self, t, ...) return ffi.new(t, ...) end,
})
imgui.new = new
imgui.GetIO = function() return { MouseDown = { false }, MousePos = { x = 0, y = 0 } } end
imgui.IsInitialized = function() return true end
imgui.CreateTextureFromFile = function() return { tex = true } end
imgui.CreateTextureFromFileInMemory = function() return { tex = true } end

-- renderer tiruan: texture dibalas sebagai lightuserdata (tanpa ffi.gc),
-- persis seperti loader sungguhan
local renderer = {}
function renderer:CreateTextureFromFile(path) return setmetatable({ path = path }, { __tostring = function() return 'lightud' end }) end
function renderer:CreateTextureFromFileInMemory(addr, size) return setmetatable({ addr = addr, size = size }, { __tostring = function() return 'lightud' end }) end
imgui.GetRenderer = function() return renderer end
imgui.ReleaseTexture = function() end
imgui.OnInitialize = function(cb) cb() end
imgui.OnFrame = function(cond, before, draw)
    frameCallbacks.before = before
    frameCallbacks.draw = draw or before
    return { Unsubscribe = function() end }
end
imgui.SwitchContext = function() end
imgui.PushStyleColorU32 = function() end
imgui.PopStyleColor = function() end
imgui.PushStyleVarFloat = function() end
imgui.PushStyleVarVec2 = function() end
imgui.PopStyleVar = function() end
imgui.StyleVar = setmetatable({}, { __index = function() return 0 end })
imgui.GetStyle = function() return setmetatable({}, { __index = function() return 0 end }) end
imgui.GetFont = function() return { ptr = true } end
imgui.SetCursorScreenPos = function(v) frame.screen = v end
imgui.AddText = function() end
imgui.SetNextWindowPos = function() end
imgui.SetNextWindowSize = function() end

-- --- fixtures: folder musikdummy -------------------------------------------
-- Dua lagu MP3 minimal: satu bertitle/ber-artwork, satu tanpa artwork, supaya
-- jalur sampul (dan jalur tanpa sampul) sama-sama ikut diuji.
local MUSIC_DIR = '/tmp/monetloader/musik'
do
    os.execute('mkdir -p ' .. MUSIC_DIR)
    local frame = string.char(0xFF, 0xFB, 0x90, 0x00) .. string.rep('\0', 413)
    for _, name in ipairs({ 'a-lagu-sampul.mp3', 'b-lagu-tanpa-sampul.mp3' }) do
        local path = MUSIC_DIR .. '/' .. name
        local f = io.open(path, 'wb')
        if f then
            f:write(string.rep(frame, 40))
            f:close()
        end
    end
end

-- --- globals loader tiruan ------------------------------------------------
local function stub(name, value) _G[name] = value end
stub('getWorkingDirectory', function() return '/tmp/monetloader' end)
-- satu cover eksternal supaya jalur artwork (AddImage/AddImageRounded) ikut jalan.
-- Calls dihitung: pencarian cover yang diulang tiap frame adalah penyebab FPS turun.
local fileChecks = 0
stub('doesFileExist', function(path)
    fileChecks = fileChecks + 1
    -- hanya lagu pertama punya cover; lagu kedua sengaja tanpa artwork
    return type(path) == 'string' and path:match('a%-lagu%-sampul%.jpg$') ~= nil
end)
stub('doesDirectoryExist', function() return true end)
stub('createDirectory', function() return true end)
stub('getScreenResolution', function() return 1600, 720 end)
local chatCommands = {}
stub('sampRegisterChatCommand', function(name, fn) chatCommands[name] = fn end)
stub('loadAudioStream', function() return { stream = true } end)
stub('releaseAudioStream', function() end)
stub('setAudioStreamState', function() end)
stub('setAudioStreamVolume', function() end)
stub('setAudioStreamPosition', function() end)
stub('getAudioStreamState', function() return 1 end)
stub('getAudioStreamLength', function() return 200 end)
stub('getAudioStreamVolume', function() return 80 end)
stub('monet_get_audiostream_handle', function() return 1 end)
stub('monet_is_audiostream_available', function() return true end)
stub('isCursorActive', function() return false end)
stub('script_name', function() end)
stub('script_author', function() end)
stub('script_version', function() end)
stub('script_version_number', function() end)
stub('script_description', function() end)
stub('script_properties', function() end)
stub('thisScript', function() return { id = 1, filename = 'sampmusic.lua' } end)
stub('MONET_VERSION', 3080000)
stub('MONET_DPI_SCALE', 1.3460499)

-- wait() keluar dari loop utama
local stop = false
stub('wait', function() stop = true; error('__stop__', 0) end)

-- --- muat skrip ----------------------------------------------------------
package.preload['mimgui'] = function() return imgui end

local chunk = assert(loadfile(scriptPath))
local ok, err = pcall(chunk)
if not ok then
    print('GAGAL MUAT: ' .. tostring(err))
    os.exit(1)
end

-- main() mengisi state; loop wait() dihentikan dengan error sentinel
local okMain, errMain = pcall(function() main() end)
if not okMain and not tostring(errMain):find('__stop__') then
    print('GAGAL main(): ' .. tostring(errMain))
    os.exit(1)
end

-- --- jalankan frame GUI beberapa kali ------------------------------------
local pages = { 'player', 'library', 'queue', 'settings', 'about' }
local failures = 0

local function runFrame()
    if frameCallbacks.before then
        local okb, errb = pcall(frameCallbacks.before, { HideCursor = false })
        if not okb then return false, errb end
    end
    if frameCallbacks.draw then
        local okd, errd = pcall(frameCallbacks.draw, { HideCursor = false })
        if not okd then return false, errd end
    end
    return true
end

-- klik semua tombol sekali
local navIds = { '##nav_player', '##nav_library', '##nav_queue',
    '##nav_settings', '##nav_about' }
clickIds = {
    ['##play'] = true, ['##next'] = true, ['##prev'] = true, ['##shuffle'] = true,
    ['##repeat'] = true, ['##mute'] = true, ['##volume'] = true,
    ['##tab_library'] = true, ['##tab_queue'] = true,
    ['##lib1'] = true, ['##queue1'] = true,
}
for _, id in ipairs(navIds) do clickIds[id] = true end

-- Sidebar memindahkan halaman saat tombolnya diklik, jadi klik navigasi
-- ditahan dulu: halaman harus ditentukan oleh perintah, bukan oleh klik.
for _, id in ipairs(navIds) do clickIds[id] = false end

-- putar satu lagu dulu, supaya kartu now-playing punya artwork
if chatCommands['music'] then pcall(chatCommands['music'], 'library') end
local okp, errp = runFrame()
if not okp then
    failures = failures + 1
    print('GAGAL frame pemutar lagu: ' .. tostring(errp))
end

for _, page in ipairs(pages) do
    local cmd = chatCommands['music']
    if cmd then
        local okc, errc = pcall(cmd, page)
        if not okc then
            failures = failures + 1
            print('GAGAL perintah ' .. page .. ': ' .. tostring(errc))
        end
    end
    -- jendela digeser dan diubah ukuran antar frame
    frame.screen = Vec2(420 - 30 * #page, 40 + 10 * #page)
    contentSize = Vec2(600 - 40 * #page, 380 - 20 * #page)

    local okf, errf = runFrame()
    if not okf then
        failures = failures + 1
        print('GAGAL frame pada halaman ' .. page .. ': ' .. tostring(errf))
    end
end

-- Pencarian artwork tidak boleh diulang tiap frame: satu stat berkas per baris
-- pustaka per frame membuat FPS turun drastis.
local checksAfterFirst = fileChecks
for _ = 1, 4 do
    if chatCommands['music'] then pcall(chatCommands['music'], 'library') end
    local okc, errc = runFrame()
    if not okc then
        failures = failures + 1
        print('GAGAL frame cek FPS: ' .. tostring(errc))
    end
end
if fileChecks > checksAfterFirst then
    failures = failures + 1
    print(string.format('GAGAL: pencarian artwork diulang tiap frame (%d stat berkas tambahan)',
        fileChecks - checksAfterFirst))
end

-- navigasi sidebar: tiap tombol harus memindahkan halaman
for _, id in ipairs(navIds) do
    for _, other in ipairs(navIds) do clickIds[other] = false end
    clickIds[id] = true
    local okn, errn = runFrame()
    if not okn then
        failures = failures + 1
        print('GAGAL frame navigasi ' .. id .. ': ' .. tostring(errn))
    end
    clickIds[id] = false
end

-- transaksi: buka jendela lewat perintah kosong
if chatCommands['music'] then pcall(chatCommands['music'], '') end
local okf, errf = runFrame()
if not okf then
    failures = failures + 1
    print('GAGAL frame jendela default: ' .. tostring(errf))
end

if failures == 0 then
    print('OK: ' .. #pages .. 'x frame GUI berjalan tanpa error')
else
    print(failures .. ' frame gagal')
    os.exit(1)
end
