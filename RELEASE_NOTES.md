**离开时暂停所有播放**
- 离开电脑时暂停所有正在播放的内容：
  - 音乐 / Spotify / QuickTime / VLC / TV / 播客
  - 浏览器所有标签页里的视频和直播（Chrome、Edge、Arc、ego lite 等 Chromium 浏览器及 Safari）
  - 抖音、IINA 等其他正在出声的 App
- 直播网页（如虎牙）暂停后会自动续播，离开期间会一直保持暂停并静音；回来点一下页面或按任意键就恢复
- 先暂停，再锁屏 / 息屏，避免按键落到锁屏密码框里
- 仍有声音时自动把 Mac 静音，回来后自动恢复
- 通话、聊天、终端、远程桌面和虚拟机永远不会被发送按键
- 设置里新增「现在测试暂停」按钮
- 浏览器需要在菜单「显示 → 开发者 → 允许 Apple 事件中的 JavaScript」中开启；首次使用会请求「控制浏览器」权限

板子固件与 1.0.0 相同，无需重新烧录。

**安装 / 更新**：`curl -fsSL https://raw.githubusercontent.com/NorwayXZ/PhoneNotify/main/install.sh | zsh`
