## MacOS Download Manager – trình tăng tốc tải xuống cho macOS

### Có gì mới ở 1.1.6
- **Video YouTube tải bằng nhiều kết nối như IDM, và nhìn thấy được:** cửa sổ tiến trình hiện thanh chia đoạn (mỗi kết nối một đoạn, xanh dương = đang nhận) và số kết nối của từng luồng hình/tiếng. Luồng hình dùng đủ số kết nối, luồng tiếng (nhỏ) dùng vài kết nối.
- Luồng là tệp thường luôn được app tải đa kết nối, kể cả khi luồng còn lại phải để yt-dlp tải (HLS) – hai việc chạy song song.
- Khi máy chủ từ chối bớt kết nối (403/429/503), app giảm tạm thời rồi **tự tăng lại** sau 15 giây (trước đây giảm luôn tới hết lượt tải).
- Chờ đúng thời điểm YouTube cho phép tải (khi video có quảng cáo đầu) thay vì bị từ chối.
- Nhật ký `~/Library/Logs/MacOS Download Manager/video.log` ghi số kết nối của từng luồng.
- **Thoát từ Dock hoặc ⌘Q chỉ đóng cửa sổ, app vẫn chạy nền trên thanh menu** (lượt tải tiếp tục); chỉ nút Thoát trên thanh menu mới tắt hẳn. Đăng xuất, khởi động lại, tắt máy và cập nhật app vẫn thoát bình thường. Có thể tắt tuỳ chọn này trong Tùy chọn → Chung.

### Có gì mới ở 1.1.5
- Khi ghép hình và tiếng thất bại, cửa sổ tiến trình **hiện đầy đủ lý do** (lỗi của ffmpeg và của macOS, định dạng và dung lượng từng phần) thay vì chỉ dòng đầu; lỗi cũng được ghi vào `~/Library/Logs/MacOS Download Manager/video.log`.
- Kiểm tra **dung lượng trống** trước khi ghép và báo rõ nếu ổ đĩa không đủ chỗ.
- macOS ghép không cần bản sao tạm thứ hai (bỏ “tối ưu cho mạng”).

### Có gì mới ở 1.1.4
- Sửa lỗi video **1080p tải xong nhưng không ghép được** hình và tiếng: app ghép bằng ffmpeg trước (cách yt-dlp dùng cho YouTube), macOS chỉ là phương án dự phòng và nay dùng đúng khoảng thời gian của từng luồng; nếu vẫn lỗi, thông báo ghi rõ lỗi của cả hai.
- Nhận đúng luồng tiếng HLS mà yt-dlp không ghi tên codec (trước đây bị bỏ qua).
- Có bài kiểm tra tải trọn vẹn kiểu YouTube 1080p: danh sách HLS hình riêng + tiếng riêng → yt-dlp → ffmpeg → MP4.
- **Tiện ích trình duyệt mang cùng số phiên bản với app** và **tự cập nhật**: khi app làm mới thư mục tiện ích, tiện ích tự nạp lại bản mới. Hết cảnh báo “Tiện ích đã cũ” sai khi tiện ích đã là bản mới nhất.
- **Cần làm một lần:** trong `brave://extensions` bấm ↻ ở tiện ích MacOS Download Manager (nếu nạp từ thư mục “Mở thư mục tiện ích trong Finder”), hoặc gỡ tiện ích cũ và nạp thư mục đó. Từ các bản sau tiện ích tự cập nhật.

### Có gì mới ở 1.1.3
- Sửa lỗi tải video YouTube xong nhưng **ghép không được (“Cannot Open”) và hai tệp tải về không mở được**: yt-dlp bản mới liệt kê thêm các luồng HLS của YouTube (bitrate cao hơn) và app đã chọn chúng; không có ffmpeg, yt-dlp lưu chúng dạng MPEG-TS trong tệp .mp4 mà macOS không mở được. Nay app ưu tiên luồng MP4 thường của YouTube (tải đa kết nối, macOS tự ghép), chỉ dùng HLS khi không còn lựa chọn khác.
- **ffmpeg được tải tự động** (một lần, bản dựng có chữ ký từ ffmpeg.martin-riedl.de, kiểm tra SHA-256 và chữ ký) cùng yt-dlp và Deno: ghép những luồng macOS không ghép được, chuyển HLS/MPEG-TS sang MP4, và mở thêm chất lượng 1440p/4K (VP9/AV1).
- Trước khi ghép, app kiểm tra định dạng thật của từng tệp; nếu macOS từ chối thì tự chuyển sang ffmpeg.
- **Lượt tải bị lỗi ghép chỉ cần bấm “Resume”**: app ghép lại các phần đã tải, không tải lại.
- Chất lượng chọn sẵn luôn là H.264 (phát được bằng QuickTime trên mọi máy Mac), trừ khi bạn đặt chất lượng tối đa trên 1080p.

### Có gì mới ở 1.1.2
- Sửa lỗi tải video báo **“[PYI-…] Failed to load Python shared library … library load disallowed by system policy”**: app không còn bật chế độ cách ly (quarantine) cho mọi tệp nó tạo ra — chế độ này bị macOS truyền sang yt-dlp và chặn thư viện Python của nó. Tệp tải xong vẫn được gắn dấu “tải từ Internet” như trình duyệt, nên macOS vẫn kiểm tra ứng dụng tải về trước khi mở.
- Mỗi bản build tự kiểm tra: mở app như người dùng, cài yt-dlp + Deno và chạy chúng từ bên trong app.

### Có gì mới ở 1.1.1
- Nút **“⬇ Download video”** trên YouTube hiện cả ở các tab YouTube đang mở sẵn khi cài/cập nhật tiện ích (không cần tải lại trang), và không dùng `innerHTML` (an toàn với chính sách Trusted Types của YouTube).
- App biết phiên bản tiện ích đang kết nối: **cảnh báo “Tiện ích trình duyệt đã cũ”** ở thanh trạng thái và trong Tùy chọn → Trình duyệt; popup tiện ích hiện số phiên bản.
- Thư mục tiện ích ổn định (Tùy chọn → Trình duyệt → “Mở thư mục tiện ích trong Finder”) được app tự cập nhật sau mỗi lần nâng cấp: chỉ cần bấm ↻ trong trang tiện ích của trình duyệt.

### Có gì mới ở 1.1.0
- **Tải video YouTube và nhiều trang video khác** (Facebook, TikTok, Vimeo, X…): chọn chất lượng, luồng hình và luồng tiếng tải song song bằng nhiều kết nối rồi ghép thành MP4 (tới 1080p; 1440p/4K khi có ffmpeg). Lần đầu dùng, app tự tải yt-dlp + Deno từ GitHub chính thức.
- Tiện ích trình duyệt: nút **“Download video from this page”** và menu chuột phải **“Download video with MacOS Download Manager”**.
- Cửa sổ **Giới thiệu** (nhà phát triển: xuanthanhtnt) và nút **Báo lỗi** (Help → Báo lỗi…).
- **Cần cập nhật tiện ích:** chép thư mục tiện ích mới trong file .dmg đè lên thư mục cũ rồi bấm ↻ (Reload) trong `brave://extensions`.

### Có gì mới ở 1.0.4
- Sửa dứt điểm lỗi trình duyệt và MacOS Download Manager cùng tải một tệp: khi app đã nhận link nhưng câu trả lời không về tới tiện ích (thường gặp trên Brave), tiện ích kiểm tra lại app và vẫn dừng bản tải của trình duyệt.
- Máy chủ tích hợp trình duyệt hỗ trợ CORS / Private Network Access và đóng kết nối an toàn hơn.
- Có bài kiểm tra tự động chạy tiện ích trong Chromium thật cho mỗi bản build.
- **Cần cập nhật tiện ích:** chép thư mục tiện ích mới trong file .dmg đè lên thư mục cũ, rồi bấm ↻ (Reload) ở tiện ích trong `brave://extensions`.

### Có gì mới ở 1.0.3
- Sửa lỗi trình tải của trình duyệt (Brave/Chrome/Edge) và MacOS Download Manager cùng tải một tệp: tiện ích chặn lượt tải trước khi trình duyệt bắt đầu lưu tệp, và kiểm tra lại cho tới khi trình duyệt dừng hẳn.
- Một link bị báo trùng nhiều lần chỉ mở một hộp thoại.
- **Cần cập nhật tiện ích:** chép thư mục tiện ích mới trong file .dmg đè lên thư mục cũ, rồi bấm ↻ (Reload) ở tiện ích trong `brave://extensions`.

### Có gì mới ở 1.0.2
- Tiện ích trình duyệt bắt được cả link không có đuôi tệp trong địa chỉ (ví dụ link tải ISO của Microsoft `go.microsoft.com/fwlink/...`): nhận diện theo tên tệp thật và loại MIME.
- Popup của tiện ích hiển thị lần tải gần nhất đã được gửi sang app hay bị bỏ qua, và lý do.
- **Cần cài lại tiện ích:** vào `brave://extensions` (hoặc `chrome://extensions`), xoá tiện ích cũ rồi “Load unpacked” thư mục mới trong file .dmg.

### Có gì mới ở 1.0.1
- Sửa lỗi treo (con trỏ xoay tròn) ngay sau khi mở ứng dụng.
- Cho phép tải link `http://` thường (trước đây macOS chặn).
- Bộ giới hạn tốc độ hoạt động chính xác hơn; tự giảm số kết nối khi máy chủ giới hạn.

**Cài đặt:** mở file `.dmg`, kéo MacOS Download Manager vào Applications, sau đó chạy một lần trong Terminal:

```bash
xattr -cr "/Applications/MacOS Download Manager.app"
```

(ứng dụng được ký ad-hoc, chưa notarize). Hỗ trợ macOS 13+ trên Apple Silicon và Intel.

### Tính năng chính
- Tải đa kết nối (tới 32) với chia đoạn động, tạm dừng/tải tiếp, tự thử lại
- Tiện ích Chrome/Edge/Brave/Firefox: tự bắt link tải, menu chuột phải, bắt video & HLS (m3u8)
- Hàng đợi & lịch hẹn giờ, giới hạn tốc độ, theo dõi clipboard, ô thả liên kết
- Tải hàng loạt, quét trang web, nhập/xuất danh sách IDM (.ef2), đăng nhập trang web, proxy
- Kiểm tra checksum, thông báo, chạy lệnh quét virus sau khi tải
- Giao diện tiếng Việt / English

Tiện ích trình duyệt nằm sẵn trong file .dmg (hoặc Options → Browser → Show Extension Folder).
