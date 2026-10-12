import Foundation

public struct LANWebAssets {
    public static let htmlUploadPage: String = """
    <!DOCTYPE html>
    <html lang="zh-CN">
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>Lovort Player — 局域网高速传输</title>
        <style>
            * { box-sizing: border-box; margin: 0; padding: 0; }
            body {
                background: #0A0A0C;
                color: #FFFFFF;
                font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", sans-serif;
                display: flex;
                flex-direction: column;
                align-items: center;
                justify-content: center;
                min-height: 100vh;
                padding: 24px;
            }
            .card {
                background: rgba(255, 255, 255, 0.04);
                backdrop-filter: blur(20px);
                border: 1px solid rgba(255, 255, 255, 0.08);
                border-radius: 24px;
                padding: 40px;
                width: 100%;
                max-width: 580px;
                text-align: center;
                box-shadow: 0 30px 60px rgba(0,0,0,0.4);
            }
            h1 { font-size: 24px; font-weight: 600; margin-bottom: 8px; }
            p { font-size: 14px; color: rgba(255,255,255,0.6); margin-bottom: 32px; }
            .dropzone {
                border: 2px dashed rgba(255, 255, 255, 0.15);
                border-radius: 18px;
                padding: 48px 20px;
                cursor: pointer;
                transition: all 0.25s ease;
            }
            .dropzone.hover {
                border-color: #00F2FE;
                background: rgba(0, 242, 254, 0.05);
            }
            .dropzone svg {
                width: 48px;
                height: 48px;
                fill: rgba(255,255,255,0.7);
                margin-bottom: 16px;
            }
            .upload-btn {
                background: #00F2FE;
                color: #000;
                font-weight: 600;
                font-size: 14px;
                padding: 10px 24px;
                border-radius: 99px;
                border: none;
                margin-top: 16px;
                cursor: pointer;
                display: inline-block;
            }
            .progress-container {
                margin-top: 24px;
                display: none;
            }
            .progress-bar {
                background: rgba(255,255,255,0.1);
                border-radius: 99px;
                height: 8px;
                overflow: hidden;
                margin-top: 8px;
            }
            .progress-fill {
                background: #00F2FE;
                height: 100%;
                width: 0%;
                transition: width 0.1s linear;
            }
            .file-list {
                margin-top: 24px;
                text-align: left;
                font-size: 13px;
                color: rgba(255,255,255,0.7);
            }
        </style>
    </head>
    <body>
        <div class="card">
            <h1>Lovort 局域网直传</h1>
            <p>将电脑中的视频拖拽至下方，直接导入至 iPhone 播放器</p>
            <div class="dropzone" id="dropzone">
                <svg viewBox="0 0 24 24"><path d="M19.35 10.04C18.67 6.59 15.64 4 12 4 9.11 4 6.6 5.64 5.35 8.04 2.34 8.36 0 10.91 0 14c0 3.31 2.69 6 6 6h13c2.76 0 5-2.24 5-5 0-2.64-2.05-4.78-4.65-4.96zM14 13v4h-4v-4H7l5-5 5 5h-3z"/></svg>
                <div>拖拽视频文件到此处，或点击浏览</div>
                <input type="file" id="fileInput" multiple accept="video/*,.mkv,.mp4,.mov,.avi" style="display:none">
                <button class="upload-btn" onclick="document.getElementById('fileInput').click()">选择本地视频</button>
            </div>
            <div class="progress-container" id="progressContainer">
                <div id="progressText" style="font-size: 13px; color: rgba(255,255,255,0.8);">上传中...</div>
                <div class="progress-bar"><div class="progress-fill" id="progressFill"></div></div>
            </div>
            <div class="file-list" id="fileList"></div>
        </div>
        <script>
            const dropzone = document.getElementById('dropzone');
            const fileInput = document.getElementById('fileInput');
            const progressContainer = document.getElementById('progressContainer');
            const progressFill = document.getElementById('progressFill');
            const progressText = document.getElementById('progressText');
            const fileList = document.getElementById('fileList');

            dropzone.addEventListener('dragover', (e) => { e.preventDefault(); dropzone.classList.add('hover'); });
            dropzone.addEventListener('dragleave', () => dropzone.classList.remove('hover'));
            dropzone.addEventListener('drop', (e) => {
                e.preventDefault();
                dropzone.classList.remove('hover');
                if (e.dataTransfer.files.length) uploadFiles(e.dataTransfer.files);
            });
            fileInput.addEventListener('change', () => {
                if (fileInput.files.length) uploadFiles(fileInput.files);
            });

            function uploadFiles(files) {
                progressContainer.style.display = 'block';
                Array.from(files).forEach(file => {
                    const xhr = new XMLHttpRequest();
                    xhr.open('POST', '/upload', true);
                    xhr.setRequestHeader('X-File-Name', encodeURIComponent(file.name));
                    xhr.upload.onprogress = (e) => {
                        if (e.lengthComputable) {
                            const percent = Math.round((e.loaded / e.total) * 100);
                            progressFill.style.width = percent + '%';
                            progressText.innerText = '正在上传 ' + file.name + ' (' + percent + '%)';
                        }
                    };
                    xhr.onload = () => {
                        if (xhr.status === 200) {
                            progressText.innerText = '上传成功: ' + file.name;
                            const item = document.createElement('div');
                            item.innerText = '✓ ' + file.name;
                            fileList.appendChild(item);
                        } else {
                            progressText.innerText = '上传失败';
                        }
                    };
                    xhr.send(file);
                });
            }
        </script>
    </body>
    </html>
    """
}
