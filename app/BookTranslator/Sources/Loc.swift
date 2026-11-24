import Foundation
import Observation

/// App language. The strings of the interface live in `Loc.table`; English is the source
/// language and Indonesian the translation, switchable at run time without a restart.
enum AppLanguage: String, CaseIterable, Identifiable {
    case id, en
    var id: String { rawValue }
    var label: String { self == .id ? "Bahasa Indonesia" : "English" }
}

@Observable
final class Loc {
    static let shared = Loc()

    var language: AppLanguage {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: "appLanguage") }
    }

    init() {
        let saved = UserDefaults.standard.string(forKey: "appLanguage")
        let system = Locale.preferredLanguages.first?.hasPrefix("id") == true ? "id" : "en"
        language = AppLanguage(rawValue: saved ?? system) ?? .en
    }

    func t(_ key: String) -> String {
        guard let pair = Loc.table[key] else { return key }
        return language == .id ? pair.1 : pair.0
    }

    func t(_ key: String, _ args: CVarArg...) -> String {
        String(format: t(key), arguments: args)
    }

    /// Translation of the style presets the engine reports by id.
    func styleName(_ id: String) -> String { t("style.\(id)") }
    func styleText(_ id: String) -> String { t("style.\(id).desc") }

    func minutes(_ value: Int) -> String {
        if value < 60 { return t("time.min", value) }
        let h = value / 60, m = value % 60
        return m == 0 ? t("time.h", h) : t("time.hm", h, m)
    }

    // swiftlint:disable line_length
    static let table: [String: (String, String)] = [
        // Navigation
        "nav.input": ("Add", "Masukkan"),
        "nav.process": ("Progress", "Proses"),
        "nav.library": ("Library", "Hasil"),
        "nav.settings": ("Settings", "Pengaturan"),
        "app.title": ("Book Translator", "Penerjemah Buku"),
        // Input
        "input.uploaded": ("Uploaded books", "Buku diunggah"),
        "input.count": ("%d books", "%d buku"),
        "input.dropHint": ("Drop books here · EPUB or TXT, as many as you like", "Seret buku ke sini · EPUB atau TXT, boleh banyak"),
        "input.choose": ("Choose files…", "Pilih file…"),
        "input.allReady": ("Every book is set up. Add new books any time.", "Semua buku sudah disiapkan. Unggah buku baru kapan saja."),
        "input.readyAll": ("Add all →", "Siapkan semua →"),
        "input.prepare": ("Add →", "Siapkan →"),
        "input.ready": ("Ready to translate", "Siap diterjemahkan"),
        "input.readyHint": ("The top book is translated first. Drag to reorder.", "Yang paling atas diterjemahkan lebih dulu. Seret untuk mengubah urutan."),
        "input.readyEmpty": ("Drag a book here from the left, or press Add.", "Seret buku dari kiri ke sini, atau tekan Siapkan."),
        "input.start": ("Start translating", "Mulai terjemahkan"),
        "input.startN": ("Start translating %d books", "Mulai terjemahkan %d buku"),
        "input.reading": ("Reading the book…", "Membaca buku…"),
        "input.volumes": ("%d volumes", "%d jilid"),
        "input.volume1": ("1 volume", "1 jilid"),
        "input.about": ("about %@", "sekitar %@"),
        "input.remove": ("Remove from list", "Hapus dari daftar"),
        "input.moveFirst": ("Move to top", "Jadikan pertama"),
        "input.backToUploaded": ("Take out of the queue", "Keluarkan dari antrean"),
        "input.toggleKind": ("Change to %@", "Ubah menjadi %@"),
        "kind.fiction": ("Fiction", "Fiksi"),
        "kind.nonfiction": ("Non-fiction", "Nonfiksi"),
        "input.reviewFirst": ("Review names and style first", "Periksa nama dan gaya dulu"),
        // Process
        "process.empty": ("Nothing is being translated", "Belum ada yang diterjemahkan"),
        "process.emptyHint": ("Add books in Add, then press Start translating.", "Siapkan buku di langkah Masukkan, lalu tekan Mulai terjemahkan."),
        "process.goInput": ("Go to Add", "Ke Masukkan"),
        "process.now": ("Translating now", "Sedang diterjemahkan"),
        "process.preparing": ("Preparing: reading names and choosing a style", "Menyiapkan: membaca nama dan memilih gaya"),
        "process.volumeOf": ("Volume %d of %d", "Jilid %d dari %d"),
        "process.thisVolume": ("This volume", "Jilid ini"),
        "process.remaining": ("about %@ left", "sisa sekitar %@"),
        "process.via": ("via %@", "lewat %@"),
        "process.pause": ("Pause", "Jeda"),
        "process.resume": ("Resume", "Lanjutkan"),
        "process.paused": ("Paused. Progress is kept.", "Dijeda. Kemajuan tersimpan."),
        "process.queue": ("Queue", "Antre"),
        "process.queueHint": ("Starts by itself, one at a time, in this order", "Dimulai otomatis, satu per satu, sesuai urutan"),
        "process.review": ("Review", "Periksa"),
        "process.needsReview": ("Needs your review", "Perlu diperiksa"),
        "process.failed": ("Stopped", "Terhenti"),
        "process.retry": ("Try again", "Coba lagi"),
        "process.waiting": ("Waiting", "Menunggu"),
        "process.noEngine": ("No translation engine is signed in. Open Settings.", "Tidak ada mesin terjemahan yang aktif. Buka Pengaturan."),
        // Review sheet
        "review.title": ("Review first: %@", "Periksa dulu: %@"),
        "review.intro": ("Recognised as fiction, so names are locked and one style is chosen for the whole book. After approval the rest runs by itself.", "Dikenali sebagai fiksi, jadi nama dikunci dan gaya dipilih sekali untuk seluruh buku. Setelah disetujui, sisanya berjalan sendiri."),
        "review.names": ("Names and terms · %d found, %d shown", "Nama dan istilah · %d ditemukan, %d ditampilkan"),
        "review.namesHint": ("Kept = written exactly as in the original throughout the book.", "Tetap = ditulis seperti aslinya di seluruh buku."),
        "review.keep": ("Kept", "Tetap"),
        "review.translate": ("Translated", "Terjemahkan"),
        "review.transliterate": ("Transliterated", "Alihaksara"),
        "review.editGlossary": ("Edit all names…", "Ubah semua nama…"),
        "review.style": ("Writing style", "Gaya bahasa"),
        "review.recommended": ("Recommended", "Disarankan"),
        "review.later": ("Later", "Nanti"),
        "review.approve": ("Approve and continue", "Setuju, lanjutkan"),
        "review.otherBooks": ("Other books in the queue do not wait. You can close this and come back.", "Buku lain di antrean tidak menunggu. Anda bisa menutup ini dan kembali nanti."),
        "review.sample": ("Sample of this style", "Contoh gaya ini"),
        "review.calibration": ("Open the sample translation…", "Buka contoh terjemahan…"),
        // Library
        "library.summary": ("%d books · %d fiction · %d non-fiction", "%d buku · %d fiksi · %d nonfiksi"),
        "library.search": ("Search", "Cari"),
        "library.group": ("Group by", "Kelompokkan"),
        "library.sort": ("Sort by", "Urutkan"),
        "library.group.kind": ("Type", "Jenis"),
        "library.group.author": ("Author", "Penulis"),
        "library.group.none": ("None", "Tanpa"),
        "library.sort.recent": ("Newest", "Terbaru"),
        "library.sort.title": ("Title", "Judul"),
        "library.sort.author": ("Author", "Penulis"),
        "library.empty": ("No matching books.", "Tidak ada buku yang cocok."),
        "library.none": ("No translated books yet", "Belum ada buku yang selesai"),
        "library.unfinished": ("Unfinished", "Belum selesai"),
        // Detail
        "detail.done": ("Done %@", "Selesai %@"),
        "detail.openBooks": ("Open in Books", "Buka di Buku"),
        "detail.reveal": ("Show in Finder", "Tampilkan di Finder"),
        "detail.redo": ("Translate again", "Terjemahkan ulang"),
        "detail.redoConfirm": ("Translate this book again? The current translation is kept in a \"previous\" folder.", "Terjemahkan buku ini lagi? Terjemahan sekarang disimpan di folder \"previous\"."),
        "detail.volumes": ("Volumes", "Jilid"),
        "detail.open": ("Open", "Buka"),
        "detail.qa": ("Translation check", "Pemeriksaan isi terjemahan"),
        "detail.qaNone": ("Nothing flagged.", "Tidak ada yang ditandai."),
        "detail.qaSome": ("%d places flagged for a look.", "%d tempat ditandai untuk dilihat."),
        "detail.qaOpen": ("Open the report…", "Buka laporannya…"),
        "detail.metadata": ("Metadata", "Metadata"),
        "detail.metadataHint": ("Check it before you keep the book in Books or on another device.", "Periksa isinya sebelum buku Anda simpan di Buku atau perangkat lain."),
        "detail.fix": ("Repair metadata", "Perbaiki metadata"),
        "detail.complete": ("All %d fields are complete", "Semua %d kolom lengkap"),
        "detail.incomplete": ("%d of %d fields need attention", "%d dari %d kolom perlu perhatian"),
        "meta.title": ("Title", "Judul"),
        "meta.creator": ("Author", "Penulis"),
        "meta.language": ("Language", "Bahasa"),
        "meta.series": ("Series", "Seri"),
        "meta.volume": ("Volume", "Jilid"),
        "meta.description": ("Description", "Deskripsi"),
        "meta.publisher": ("Publisher", "Penerbit"),
        "meta.date": ("Date", "Tanggal"),
        "meta.subject": ("Subjects", "Subjek"),
        "meta.identifier": ("Identifier", "Pengenal"),
        "meta.cover": ("Cover", "Sampul"),
        "meta.source": ("Original title", "Judul asli"),
        "meta.present": ("Present", "Ada"),
        "meta.missing": ("Missing", "Tidak ada"),
        "meta.titleNote": ("Kept in the original language", "Tetap bahasa asli"),
        "meta.languageNote": ("Translated into Indonesian", "Diterjemahkan ke Indonesia"),
        "lang.id": ("Indonesian", "Indonesia"),
        "lang.en": ("English", "Inggris"),
        // Settings
        "settings.language": ("App language", "Bahasa aplikasi"),
        "settings.languageHint": ("Changes the whole app at once.", "Mengubah seluruh aplikasi sekaligus."),
        "settings.version": ("Version and updates", "Versi dan pembaruan"),
        "settings.versionNow": ("Version %@ (%@)", "Versi %@ (%@)"),
        "settings.check": ("Check for updates", "Periksa pembaruan"),
        "settings.checking": ("Checking…", "Memeriksa…"),
        "settings.upToDate": ("You have the latest version.", "Anda memakai versi terbaru."),
        "settings.available": ("Version %@ is available", "Versi %@ tersedia"),
        "settings.install": ("Update now", "Perbarui sekarang"),
        "settings.installing": ("Downloading…", "Mengunduh…"),
        "settings.auto": ("Update automatically", "Perbarui otomatis"),
        "settings.autoHint": ("Installs only when no translation is running, so work is never interrupted.", "Dipasang hanya saat tidak ada terjemahan berjalan, jadi pekerjaan tidak terputus."),
        "settings.waitIdle": ("The update installs when the queue is empty.", "Pembaruan dipasang saat antrean kosong."),
        "settings.updateFailed": ("Could not check: %@", "Tidak dapat memeriksa: %@"),
        "settings.engines": ("Translation engines", "Mesin terjemahan"),
        "settings.enginesHint": ("Found by itself. The first active one translates; the others step in if it stops.", "Ditemukan otomatis. Yang pertama aktif menerjemahkan; yang lain menggantikan bila berhenti."),
        "settings.main": ("Main", "Utama"),
        "settings.backup": ("Backup", "Cadangan"),
        "settings.inactive": ("Not active", "Tidak aktif"),
        "settings.detecting": ("Checking engines…", "Memeriksa mesin…"),
        "settings.recheck": ("Check again", "Periksa lagi"),
        "settings.quality": ("Quality", "Kualitas"),
        "settings.q.economy": ("Economy", "Hemat"),
        "settings.q.balanced": ("Balanced", "Seimbang"),
        "settings.q.best": ("Best", "Terbaik"),
        "settings.qualityHint": ("Best uses the strongest model on every book; Economy saves quota on simple text.", "Terbaik memakai model terkuat di setiap buku; Hemat menghemat kuota untuk teks sederhana."),
        "settings.folder": ("Library folder", "Folder pustaka"),
        "settings.backend": ("Translator engine folder", "Folder mesin penerjemah"),
        "settings.choose": ("Choose…", "Pilih…"),
        "settings.reveal": ("Show", "Tampilkan"),
        "settings.notifications": ("Notifications", "Notifikasi"),
        "settings.notificationsHint": ("Tell me when a book finishes, needs review, or an engine is switched.", "Beri tahu saya saat buku selesai, perlu diperiksa, atau mesin berganti."),
        "settings.backendMissing": ("The translator engine was not found here. Choose the folder that contains translate_book.py.", "Mesin penerjemah tidak ditemukan di sini. Pilih folder yang berisi translate_book.py."),
        // Menu bar and notifications
        "menu.idle": ("Idle", "Tidak ada yang berjalan"),
        "menu.open": ("Open Book Translator", "Buka Penerjemah Buku"),
        "menu.quit": ("Quit", "Keluar"),
        "notify.done": ("Finished: %@", "Selesai: %@"),
        "notify.doneBody": ("The translation is in your library.", "Terjemahannya ada di pustaka Anda."),
        "notify.review": ("Needs your review: %@", "Perlu diperiksa: %@"),
        "notify.reviewBody": ("Check the names and the style, then continue.", "Periksa nama dan gaya, lalu lanjutkan."),
        "notify.failed": ("Stopped: %@", "Terhenti: %@"),
        "notify.engine": ("Switched to %@", "Beralih ke %@"),
        "notify.engineBody": ("The previous engine stopped, so the translation continues.", "Mesin sebelumnya berhenti, jadi terjemahan dilanjutkan."),
        // Styles
        "style.formal": ("Formal and restrained", "Formal dan terukur"),
        "style.formal.desc": ("Saya and Anda between characters, complete sentences, a polite measured tone.", "Saya dan Anda antartokoh, kalimat lengkap, nada sopan dan terukur."),
        "style.santai": ("Casual and modern", "Santai dan modern"),
        "style.santai.desc": ("Aku and kamu between close characters, short sentences, everyday wording.", "Aku dan kamu antartokoh dekat, kalimat pendek, kata sehari-hari."),
        "style.sastra": ("Literary and poetic", "Sastrawi dan puitis"),
        "style.sastra.desc": ("Rich diction and long rhythmic sentences, atmosphere and imagery first.", "Diksi kaya dan kalimat panjang berirama, suasana dan citraan diutamakan."),
        // Time
        "time.min": ("%d min", "%d menit"),
        "time.h": ("%d h", "%d jam"),
        "time.hm": ("%d h %d min", "%d jam %d menit"),
        // Common
        "common.cancel": ("Cancel", "Batal"),
        "common.ok": ("OK", "OK"),
        "common.error": ("Something went wrong", "Terjadi masalah"),
    ]
}
