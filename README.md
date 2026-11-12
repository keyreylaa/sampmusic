# SAMP MUSIC

Pemutar musik lokal untuk **GTA: San Andreas Multiplayer** di Android, berjalan di atas
**MonetLoader** (LuaJIT / Lua 5.1).

Skripnya memindai folder musik, membaca metadata berkas (judul, artis, album, durasi, sampul),
memutar berkas lokal maupun stream URL, dan menampilkan semuanya lewat **mimgui**.

```
┌────────────────────────────────────────────────────────────┐
│ ♪ SAMP MUSIC                                      –   ✕    │
├──────────────┬─────────────────────────────────────────────┤
│ ♪ Player      │  [ artwork ]  judul lagu                   │
│ ▤ Library     │               artis                        │
│ ☰ Queue       │               00:00 / 03:21                 │
│ ⚙ Settings    │  ───────────────────────────────────────  │
│ ⓘ About       │  ⤨  ⏮  ▶  ⏭  🔁   🔊 ──────── 80%        │
│               │                                             │
└──────────────┴─────────────────────────────────────────────┘
```

## Kebutuhan

- Android dengan **MonetLoader 3.8.0** atau lebih baru.
- Pustaka audio BASS. Loader membawanya sendiri (`libbass.so`), jadi tidak perlu dipasang.
- Folder musik: `<folder kerja loader>/musik/`.

## Pasang

1. Salin `sampmusic.lua` ke folder loader:
   `/storage/emulated/0/Android/media/com.senasamp.game/monetloader/`
2. Salin berkas musik ke subfolder `musik/` di folder yang sama.
   Format yang dibaca: `.mp3`, `.wav`, `.wave`, `.ogg`, `.flac`.
3. Mulai game. Jendelanya **tidak** muncul sendiri; buka dengan perintah `/music`.

## Perintah

| Perintah | Fungsi |
|---|---|
| `/music` | buka jendela |
| `/music player` | buka halaman Player |
| `/music library` | buka halaman Library |
| `/music queue` | buka halaman Queue |
| `/music settings` | buka halaman Settings |
| `/music about` | buka halaman About |
| `/music play` / `pause` | putar atau jeda |
| `/music next` / `prev` | lagu berikutnya / sebelumnya |
| `/music volume <0-100>` | atur volume |
| `/music refresh` | pindai ulang folder musik |

## Halaman

- **Player** — sampul, judul, artis, waktu, dan posisi lagu.
- **Library** — daftar seluruh lagu, dengan pencarian. Klik satu baris untuk memutar.
- **Queue** — antrean lagu yang akan diputar berikutnya.
- **Settings** — stream URL, pindai ulang folder, dan lokasi folder musik.
- **About** — identitas skrip dan lisensinya.

Navigasi memakai sidebar kiri; baris playback (shuffle, previous, play, next, repeat, volume)
berada di satu baris di bawah area konten dan selalu terlihat, apa pun halaman yang terbuka.

## Cara kerja

- **Pustaka** dipindai bertahap: beberapa berkas per frame, supaya render tidak tersendat.
  Metadata dibaca dari header ID3v2/ID3v1, FLAC, Ogg Vorbis, dan WAV. Durasi MP3 dihitung
  dari header frame-nya.
- **Sampul** diambil dari gambar di dalam tag (APIC/PIC) atau dari berkas sampul di samping
  lagunya. Texture dibuat sesuai kebutuhan, hanya untuk baris yang terlihat, dan dilepas
  saat tidak dipakai.
- **Audio** memakai BASS lewat API loader (`loadAudioStream`, `setAudioStreamState`, dan
  sejenisnya). Posisi lagu dibaca lewat FFI ke `libbass.so` supaya presisi, karena API loader
  tidak menyediakannya.
- **Antarmuka** memakai mimgui. Ukuran semua komponen mengikuti skala layar
  (`MONET_DPI_SCALE`, atau resolusi layar kalau variabel itu tidak ada).

## Kalau ada yang tidak jalan

| Gejala | Penyebab dan cara pragmatis |
|---|---|
| Pustaka kosong | Folder musik salah, atau berkas berekstensi lain. Cek lokasi folder di halaman Settings, lalu `/music refresh`. |
| Tidak ada suara | Volume 0 atau muted; cek tombol speaker. Stream URL harus direct audio, bukan halaman YouTube. |
| Tulisan tidak pas | Skrip memakai `MONET_DPI_SCALE` bila ada, kalau tidak memakai resolusi layar. |
| Lagu tidak diputar | Format di luar daftar (mp3, wav, wave, ogg, flac). |

## Lisensi

SAMP MUSIC ini berlisensi **GNU General Public License v3.0 (GPL-3.0)**.
Kode sumbernya ada di repo publik:

```
https://github.com/keyreylaa/sampmusic
```

### Arti lisensi GPL-3.0, singkatnya

GPL-3.0 adalah lisensi *copyleft*: Anda boleh memakai dan mengubah kode ini, tetapi setiap
versi yang Anda bagikan harus tetap GPL-3.0, dan penerimanya harus diberi tahu bahwa
kodenya GPL.

### Boleh apa

- memakai skrip ini di HP Anda sendiri;
- menyalin dan mengubahnya;
- membagikannya, gratis atau berbayar;
- menjadikannya bagian dari proyek lain, selama proyek itu juga GPL-3.0.

### Wajib apa

1. **Menyertakan pemberitahuan hak cipta dan lisensi ini** saat Anda menyalin atau
   mendistribusikan ulang skrip. Potongan berikut harus ikut:

   ```
   Copyright (C) 2026 Sena
   This program is free software: you can redistribute it and/or modify
   it under the terms of the GNU General Public License as published by
   the Free Software Foundation, either version 3 of the License, or
   (at your option) any later version.
   ```

2. **Menyatakan perubahan** yang Anda buat. Kalau Anda mendistribusikan ulang, tulis
   perubahannya.
3. **Menyertakan sumbernya.** Kalau Anda membagikan berkas `.lua` yang sudah diubah, Anda
   harus juga memberi jalan ke sumber versinya (misalnya repo publik).
4. **Memakai lisensi yang sama.** Versi turunan tetap GPL-3.0. Anda tidak boleh memaksakan
   lisensi yang lebih ketat (misalnya closed source) atas kode ini.
5. **Tidak memakai nama "Sena" atau "SAMP MUSIC"** untuk versi yang Anda ubah menjadi
   closed source, supaya tidak mengecoh pengguna asli. Boleh memakai nama lain, misalnya
   "SAMP MUSIC Community".

### Yang tidak boleh

- menutup sumber modifikasinya menjadi proprietary;
- messagerie kode ini di dalam aplikasi closed source tanpa menyediakan sumber bagian ini;
- memakai nama proyek untuk menyesatkan.

### GPL-3.0 dalam satu kalimat

> Anda boleh memakai, mengubah, dan menjual ulang kode ini, tetapi perlu memberikan sumber
> kodenya, menyatakan perubahan Anda, dan tetap lisensinya GPL-3.0.

Teks lisensi lengkap ada di berkas `LICENSE` (GPL-3.0, 674 baris). Kalau ragu soal
penggunaan tertentu, bacalah teks resminya di
<https://www.gnu.org/licenses/gpl-3.0.html>.

## Kontribusi

Fork, pull request, atau laporan bug sangat welcome. yang assists:
- bug di pembaca metadata (ID3, FLAC, Ogg, WAV);
- dukungan format lain;
- bahasa antarmuka selain bahasa Indonesia.

## Credits

- **Sena Engine** — penulis skrip.
- **MonetLoader** — loader Lua untuk Android.
- **Dear ImGui** — antarmuka.
- **BASS** — mesin audio.
