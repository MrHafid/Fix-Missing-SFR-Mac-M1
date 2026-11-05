Update macOS gagal terus dengan error "Failed to personalize the software update"? 🍎
Di kasusku, penyebabnya partisi System Recovery (Apple_APFS_Recovery) di Mac Apple Silicon hilang. Di log muncul: MSU 1256 "Failed to find SFR recovery volume".
Aku bikin script untuk membuat ulang partisinya tanpa erase/DFU restore. Berhasil update 26.1 → 27.2.
⚠️ Backup dulu, matikan SIP, jalankan DRY_RUN=1 dulu.
