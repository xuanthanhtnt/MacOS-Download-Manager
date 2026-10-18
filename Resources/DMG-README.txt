MacOS Download Manager – Trình tăng tốc tải xuống cho macOS
============================================================

CÀI ĐẶT
1. Kéo biểu tượng MacOS Download Manager vào thư mục Applications.
2. Vì ứng dụng chưa được Apple công chứng (notarize), lần đầu mở macOS sẽ chặn.
   Cách mở:
   - Mở Terminal và chạy:   xattr -cr "/Applications/MacOS Download Manager.app"
     rồi mở MacOS Download Manager như bình thường, HOẶC
   - Chuột phải vào MacOS Download Manager trong Applications → Open → Open.
     (macOS 15 trở lên: System Settings → Privacy & Security → kéo xuống → "Open Anyway").

TÍCH HỢP TRÌNH DUYỆT (bắt link tải tự động như IDM)
- Chrome / Edge / Brave / Opera / Vivaldi / Arc:
  mở chrome://extensions → bật "Developer mode" → "Load unpacked" →
  chọn thư mục "Browser Extension (Chrome, Edge, Brave)" (nên chép thư mục này ra một nơi cố định trước).
- Firefox: about:debugging → This Firefox → "Load Temporary Add-on…" → chọn manifest.json
  trong thư mục "Browser Extension (Firefox)".
- Safari: kéo-thả link vào cửa sổ MacOS Download Manager, sao chép link (MacOS Download Manager theo dõi clipboard),
  hoặc dùng bookmarklet trong MacOS Download Manager → Options → Browser.

-------------------------------------------------------------

INSTALL
1. Drag MacOS Download Manager into the Applications folder.
2. The app is not notarized by Apple. To open it the first time, run
   xattr -cr "/Applications/MacOS Download Manager.app"   in Terminal,
   or right-click MacOS Download Manager → Open → Open
   (macOS 15+: System Settings → Privacy & Security → "Open Anyway").

BROWSER INTEGRATION
- Chromium browsers: chrome://extensions → Developer mode → Load unpacked →
  choose the "Browser Extension (Chrome, Edge, Brave)" folder.
- Firefox: about:debugging → This Firefox → Load Temporary Add-on → manifest.json.

https://github.com/xuanthanhtnt/MacOS-Download-Manager
