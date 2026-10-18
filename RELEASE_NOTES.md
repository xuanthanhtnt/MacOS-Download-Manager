## MacOS Download Manager – trình tăng tốc tải xuống cho macOS

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
