# Perbaikan Partisi System Recovery (SFR) yang Hilang

## Masalah

Update ke macOS 27.2 gagal dengan error:

```
MobileSoftwareUpdateErrorDomain Code=1256 "Failed to find SFR recovery volume"
SUMacControllerErrorPreflightPersonalizeFailed=7723
```

Penyebab: partisi `disk0s3 Apple_APFS_Recovery` (System Recovery) tidak ada.

Kondisi disk saat dicek (2026-11-03, macOS 26.1, arm64):

```
/dev/disk0 (500.3 GB)
   1: Apple_APFS_ISC   disk0s1   524.3 MB   <- ada, JANGAN DISENTUH
   2: Apple_APFS       disk0s2   499.8 GB   <- Macintosh HD (container disk2)
   3: Apple_APFS_Recovery        ~5 GB      <- HILANG
```

Ruang yang belum dialokasikan di container disk2: 47.9 GB, jadi cukup untuk dikecilkan 5 GB.

Sumber:
- Reddit r/MacOS 1c2uy4x (kasus yang sama, OP berhasil memperbaikinya)
- Panduan manual: https://pastebin.com/raw/cEWvLUSR
- Script: https://gist.github.com/shivammathur/eafa182182e0873c53768f9b1212e37d

---

## Langkah 0: Backup (WAJIB)

- [ ] Backup penuh dengan Time Machine ke disk eksternal.
- [ ] Pastikan backup selesai tanpa error.

## Langkah 1: Matikan SIP

1. Matikan Mac.
2. Tekan dan **tahan** tombol power sampai muncul "Loading startup options".
3. Pilih **Options**, lalu **Continue**, dan login sebagai admin.
4. Buka menu **Utilities**, lalu **Terminal**, dan jalankan:
   ```
   csrutil disable
   ```
5. Konfirmasi, lalu restart ke macOS.
6. Cek statusnya di Terminal:
   ```
   csrutil status
   ```
   Hasil yang diharapkan: `System Integrity Protection status: disabled.`

## Langkah 2: Persiapan

- [ ] Colok charger.
- [ ] Tutup semua aplikasi.
- [ ] Matikan Tailscale/VPN.
- [ ] Cek kesehatan disk dan batas resize (read-only, aman dijalankan):
  ```
  diskutil verifyVolume disk2
  diskutil apfs resizeContainer disk0s2 limits
  diskutil list disk0
  ```

## Langkah 3: Buat ulang partisi Recovery (pakai script gist)

Download dan jalankan script **tanpa** `INSTALL_UPDATE`, supaya script hanya membuat partisinya:

```
curl -fsSL https://gist.githubusercontent.com/shivammathur/eafa182182e0873c53768f9b1212e37d/raw/fix-sfr-recovery.sh -o ~/fix-sfr-recovery.sh
chmod +x ~/fix-sfr-recovery.sh
~/fix-sfr-recovery.sh
```

Yang dilakukan script:
1. Mengecilkan `disk0s2` sebesar 5,368,684,544 bytes.
2. Menambah partisi bertipe GUID `52637672-7900-11AA-AA11-00306543ECAC`.
3. Membuat container APFS dan volume `Recovery` dengan role R.
4. Mengubah tipe partisi menjadi `AF0C` dengan `sgdisk` (gptfdisk diinstall lewat Homebrew kalau belum ada).

### Alternatif manual (versi Pastebin)

Pakai ini kalau script gagal:

```
sudo diskutil apfs resizeContainer disk0s2 <ukuran_sekarang - 5368684544>B
sudo diskutil addPartition disk0 APFS DeleteMe 5368664064
sudo diskutil apfs deleteVolume DeleteMe
diskutil list
sudo diskutil apfs addVolume diskX APFS Recovery -role R
sudo gdisk /dev/disk0
```

Ganti `diskX` dengan nomor container baru dari output `diskutil list`.

Di dalam gdisk:
1. `p`: tampilkan tabel partisi.
2. `t`: ubah tipe partisi. Pilih partisi `3`, lalu isi kode `AF0C`.
3. `p`: pastikan partisi 3 sekarang bertipe Apple APFS Recovery.
4. `w`: simpan dan keluar.

## Langkah 4: Verifikasi

```
diskutil list disk0
diskutil apfs list
```

Hasil yang diharapkan:
- Ada `disk0s3 Apple_APFS_Recovery` sekitar 5.4 GB.
- Container baru berisi satu volume `Recovery` dengan role (Recovery).

## Langkah 5: Coba update

1. Buka System Settings → General → Software Update.
2. Pilih **macOS 27.2**.
3. Kalau gagal, cek penyebabnya:
   ```
   grep -iE "personaliz|SFR|1256" /var/log/install.log | tail -20
   ```

## Langkah 6: Kalau update masih gagal, DFU Revive (butuh Mac lain)

1. Di Mac lain, install **Apple Configurator** dari App Store.
2. Sambungkan kedua Mac dengan kabel USB-C ke **port DFU** MacBook ini.
3. Masuk mode DFU di MacBook ini.
4. Di Apple Configurator, klik kanan perangkat, lalu pilih **Advanced → Revive Device** (BUKAN Restore).
5. Revive akan mengisi System Recovery ke partisi yang baru dibuat. Data tetap aman.
6. Ulangi Langkah 5.

Kalau Revive gagal, pilihan terakhirnya adalah **DFU Restore** (semua data terhapus), lalu kembalikan data dari backup Time Machine.

## Langkah 7: Nyalakan SIP lagi

Pilih salah satu:
- Di Recovery (tahan tombol power, lalu Terminal): `csrutil enable`
- Di macOS: `sudo bputil -f`

Cek dengan `csrutil status`. Hasil yang diharapkan: `enabled`.

---

## Larangan

- Jangan menghapus atau mengubah `disk0s1` (Apple_APFS_ISC). Mac bisa tidak bisa boot sama sekali.
- Jangan menjalankan script kalau partisi `Apple_APFS_Recovery` sudah ada.
- Jangan memilih **Restore** di Apple Configurator kecuali memang siap kehilangan semua data.
