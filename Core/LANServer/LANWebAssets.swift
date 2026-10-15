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
                font-size: 14px;
                color: rgba(255,255,255,0.85);
            }
            .file-item {
                background: rgba(255,255,255,0.05);
                border-radius: 10px;
                padding: 10px 14px;
                margin-bottom: 8px;
                display: flex;
                align-items: center;
                justify-content: space-between;
            }
            .file-success {
                color: #00F2FE;
                font-weight: 600;
                font-size: 12px;
            }
        </style>
    </head>
    <body>
        <div class="card">
            <h1>Lovort 局域网直传</h1>
            <p>将电脑中的视频拖拽至下方；连接中断后重新选择同一文件即可续传</p>
            <div class="dropzone" id="dropzone">
                <svg viewBox="0 0 24 24"><path d="M19.35 10.04C18.67 6.59 15.64 4 12 4 9.11 4 6.6 5.64 5.35 8.04 2.34 8.36 0 10.91 0 14c0 3.31 2.69 6 6 6h13c2.76 0 5-2.24 5-5 0-2.64-2.05-4.78-4.65-4.96zM14 13v4h-4v-4H7l5-5 5 5h-3z"/></svg>
                <div>拖拽视频文件到此处，或点击浏览</div>
                <input type="file" id="fileInput" multiple accept="video/*,.mkv,.mp4,.mov,.avi,.webm,.flv,.wmv,.ts,.m2ts,.vob,.ogv" style="display:none">
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

            async function uploadFiles(files) {
                progressContainer.style.display = 'block';
                for (const file of Array.from(files)) {
                    try { await uploadOne(file); }
                    catch (error) { progressText.textContent = '❌ ' + file.name + '：' + error.message + '。重新选择同一文件可续传。'; }
                }
            }

            function uploadID() {
                return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, c => {
                    const n = Math.floor(Math.random() * 16);
                    return (c === 'x' ? n : (n & 3 | 8)).toString(16);
                });
            }

            async function uploadOne(file) {
                const key = 'lovort-upload:' + file.name + ':' + file.size + ':' + file.lastModified;
                let id;
                try { id = localStorage.getItem(key) || uploadID(); localStorage.setItem(key, id); }
                catch (_) { id = uploadID(); }
                const headers = {
                    'X-Upload-Token': '{{UPLOAD_TOKEN}}',
                    'X-Upload-ID': id,
                    'X-File-Name': encodeURIComponent(file.name),
                    'X-File-Size': String(file.size)
                };
                async function getStatus() {
                    const response = await fetch('/upload/status', { method: 'POST', headers });
                    if (!response.ok) throw new Error(await response.text());
                    return response.json();
                }
                let state;
                try { state = await getStatus(); }
                catch (_) {
                    id = uploadID();
                    headers['X-Upload-ID'] = id;
                    try { localStorage.setItem(key, id); } catch (_) {}
                    state = await getStatus();
                }
                let failures = 0;
                while (!state.complete && state.offset < file.size) {
                    const offset = state.offset;
                    const chunk = file.slice(offset, Math.min(file.size, offset + 4 * 1024 * 1024));
                    const startedAt = performance.now();
                    try {
                        state = await new Promise((resolve, reject) => {
                            const xhr = new XMLHttpRequest();
                            xhr.open('POST', '/upload/chunk', true);
                            xhr.setRequestHeader('X-Upload-Token', '{{UPLOAD_TOKEN}}');
                            xhr.setRequestHeader('X-Upload-ID', id);
                            xhr.setRequestHeader('X-Upload-Offset', String(offset));
                            xhr.upload.onprogress = event => {
                                const sent = offset + event.loaded;
                                const percent = Math.floor(sent * 100 / file.size);
                                const elapsed = Math.max((performance.now() - startedAt) / 1000, 0.01);
                                const mbps = (event.loaded / elapsed / 1048576).toFixed(1);
                                progressFill.style.width = percent + '%';
                                progressText.textContent = '正在上传 ' + file.name + ' · ' + percent + '% · ' + mbps + ' MB/s';
                            };
                            xhr.onload = () => xhr.status === 200 ? resolve(JSON.parse(xhr.responseText)) : reject(new Error(xhr.responseText || '分片上传失败'));
                            xhr.onerror = () => reject(new Error('连接中断'));
                            xhr.send(chunk);
                        });
                        failures = 0;
                    } catch (error) {
                        failures++;
                        if (failures >= 3) throw error;
                        await new Promise(resolve => setTimeout(resolve, 600));
                        state = await getStatus();
                    }
                }
                try { localStorage.removeItem(key); } catch (_) {}
                progressFill.style.width = '100%';
                progressText.textContent = '✅ 传输成功！手机端已自动存入媒体库';
                const item = document.createElement('div');
                item.className = 'file-item';
                const name = document.createElement('span');
                name.textContent = state.savedName || file.name;
                const status = document.createElement('span');
                status.className = 'file-success';
                status.textContent = '已保存到 iPhone';
                item.appendChild(name);
                item.appendChild(status);
                fileList.appendChild(item);
            }
        </script>
    </body>
    </html>
    """
}
