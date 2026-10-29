# Margin 代码审查（2026-10-29）

全量审查了 `Sources/MarginCore`、`Sources/Margin`、`WebEditor/src` 和 vendored 引擎里 Margin 用到的路径。
每条发现都先用测试或脚本复现，再改代码。改动都尽量小，按文件独立，方便单独 revert
（`git checkout -- <file>`；回退 `WebEditor/src` 下任何文件后需要重跑 `scripts/build-editor.sh`）。

## 改动一览

| 区域 | 文件 | 说明 |
| --- | --- | --- |
| 引擎补丁 | `Vendor/swift-markdown-engine/.../NativeTextViewWrapper.swift`、`Vendor/README.md` | Native 编辑器实时应用行宽 |
| MarginCore | `Drafts.swift`、`MarkdownEditing.swift`、`MarkdownTable.swift`、`MarkdownFiles.swift`、`TabTitles.swift` | CRLF 处理、几处逻辑错误、草稿图片迁移 |
| App 层 | `WorkspaceWindowController.swift`、`AppDelegate.swift` | 保存 / 关闭 / 退出 / 侧边栏 / 监听 |
| Web 编辑器 | `markdown.ts`、`nodes.ts`、`editor.ts`、`find.ts`、`sourcemap.ts`、`main.ts`、`package.json`、`package-lock.json` | Markdown 往返保真、查找替换、源码模式定位、导出 |
| 打包产物 | `Sources/Margin/Resources/Editor/editor.js` | 由 `scripts/build-editor.sh` 重新生成 |
| 测试 | `Tests/MarginCoreTests/*`、`Tests/MarginTests/WorkspaceTests.swift`、`Tests/MarginTests/NativeReadingWidthTests.swift`（新）、`WebEditor/test/regressions.test.mjs`（新） | 每个修复一条回归测试（需要弹窗的除外） |

## 已修复

### 引擎（Native 编辑器）

1. **设置里的 Line width 在 Native 模式下不生效。** 引擎的 `NativeTextViewWrapper` 只在 `makeNSView` 里设置一次换行宽度，之后 `updateNSView` 从不重新应用 `readingWidth`，所以拖滑块没有任何反应，只有重启或切换引擎才生效。补丁在 `updateNSView` 里检测 `readingWidth` 变化，重设文字容器宽度、重新测量并居中。以 `[Margin patch]` 标注，记录在 `Vendor/README.md`。测试：`NativeReadingWidthTests`。

### MarginCore

CRLF 相关（2–6）同一个根因：Swift 的 `String` 把 `"\r\n"` 当成一个 Character，`split`/`hasPrefix`/`hasSuffix("\n")` 都看不到里面的 `\n`。Web 编辑器保存时会把文件转成 LF，所以只影响 Native 编辑器打开的 Windows 换行文件。

2. **`DocumentTitle.from` 对 CRLF 文档返回整篇内容作标题。** 新建文件自动改名时会得到形如 `Plan\r\n\r\nlorem….md` 的文件名。修复：先把 `\r\n` 归一成 `\n`。
3. **`MarkdownTable.at` 在 CRLF 文档里把最后一行的换行算进表格范围。** 每次表格操作（Tab、加行、对齐）都吃掉表格后的一个换行，连续操作会把后面的正文拉进表格；表格内部换行还会变成 LF。修复：用 `getLineStart(contentsEnd:)` 取不含换行的终点，并记住文本的换行符在 `formatted()` 里沿用。
4. **光标在表格后的空行上时被判定为在表格最后一格里。** 此时 Tab 会给表格加一行，"Delete table" 会删掉表格。原因是 `min(caret, length - 1)` 的夹取把文末光标映射到了最后一行的换行上。修复：不再夹取，行索引改为"起点 ≤ 光标的最后一行"。
5. **`setLineKind` 对含空行的 CRLF 选区会多出一行（列表、引用）或丢掉 `\r`（标题）。** 修复：按文本自己的换行符拆分和拼接。
6. **`insertBlock` 在 CRLF 文档里多插空行、产生混合换行。** 修复：检测文档换行符，前后留白和块内容都用它。
7. **`headings()` 对缩进 1–3 空格的标题保留了 `##` 作为标题文字；4 空格缩进的代码行被当成标题。** 影响大纲和导轨。修复：从去掉缩进后的内容取标题，缩进 ≥ 4 不算标题。
8. **粗斜体 `***a***` 上再切换斜体变成 `****a****`。** `isBoldBoundary` 只看相邻两个星号，`***` 也满足。修复：只有两侧恰好是两个星号时才视为粗体边界。
9. **`state()` 把 `* item` 这种星号列表判成斜体，**工具栏斜体按钮亮起。修复：统计行内标记前先跳过块前缀。
10. **多行选区设置块样式后，新选区比应有的短**（短 `sel.location - range.location` 个字符）。修复：按原选区终点加增量计算。
11. **同名标签页的目录提示在根目录下显示为 `//a` 或 `/`。** 修复：路径组件里去掉根 `/`，没有父目录时不显示提示。

### App 层

12. **草稿（无文件夹窗口里 ⌘N 的文档）Save As 后图片全部失效。** 粘贴的截图被存进 `~/Library/Application Support/Margin/Drafts/assets/`，Save As 原样写出 Markdown 并删掉草稿，相对路径从此指向错误位置，图片文件留在 Drafts 里。修复：新增 `Drafts.relocateImages`，保存时把 `assets/` 里引用的图片搬到新位置旁的 `assets/`，其他相对链接按新位置重算，然后 `editor.reload` 让编辑器拿到改写后的文本。测试：`DocumentTitleTests.testSavingADraftTakesItsImagesAlong`。
13. **自动保存持续失败（只读文件等）的标签页既关不掉也无法退出。** 开启自动保存时 `resolveUnsaved` 直接返回写入结果，失败就卡住，横幅上只有 Try Again。修复：写入失败则继续走"保存 / 取消 / 不保存"对话框。需手测。
14. **侧边栏 "Move to Trash" 丢弃打开标签页里未保存的编辑。** 原来是先删文件再直接移除标签页。修复：先按正常流程关闭受影响的标签页（会保存或询问），再移到废纸篓；文件已随空标签页删除时跳过。需手测。
15. **每次磁盘变化（包括自己的自动保存）都会重新展开用户刚折叠的文件夹。** `reloadTree` 完成后总是调用 `revealActiveInTree`。修复：树重载不再展开，展开只在打开 / 切换标签时发生（`updateTitle` 已经做了）。测试：`testReloadingTheTreeDoesNotReexpandACollapsedFolder`。
16. **退出时最小化的窗口不会被记进会话。** `saveSession` 只遍历 `NSApp.orderedWindows`（仅屏幕上的窗口）。修复：补上不在其中的控制器，和 `AppDelegate.open` 的做法一致。需手测。
17. **多窗口退出被取消后，已被删除的空 `Untitled.md` 的标签页还留着。** `prepareToClose` 在每个窗口确认时就删文件，后面的窗口一取消，前面的标签页就指向不存在的文件。修复：删除挪到所有窗口都同意之后（`removeEmptyUntitledFiles`，在 `windowWillClose` 和 `applicationShouldTerminate` 末尾调用）。测试：`testEmptyNewFileGoesOnlyOnceEveryWindowAgreedToClose`。
18. **空草稿退出时不清理，每次启动都恢复一个 Untitled 标签页，越积越多。** 修复：上面的清理同样覆盖空草稿（关窗口的路径本来就会删）。测试：`testEmptyDraftIsRemovedWhenQuitting`。
19. **重命名文件夹后，它里面原本展开的子文件夹全部折叠。** 只迁移了被重命名文件夹自己的键。修复：前缀匹配迁移所有子键。需手测。
20. **在设置里打开自动保存时，未保存的小圆点消失，但内容并没有写盘。** 修复：自动保存从关到开时把所有待写内容写出。测试：`testTurningAutosaveOnWritesPendingEdits`。
21. **连按两次 ⌘W（或双击关闭按钮）会排队两个"保存更改？"对话框。** 修复：关闭中的标签页记在 `closingTabs`，第二次调用直接返回。
22. **通过符号链接打开的文件夹收不到外部修改通知。** FSEvents 报告真实路径，比较时用的是链接路径。修复：监听和比较都用解析后的路径（文件本身可能已删除，所以只解析它的目录）。需手测。

### Web 编辑器

23. **front matter 前面一旦出现节点就整段丢失。** 在 YAML 开头按 ↑/← 会落下一个 gap cursor，此时输入会在 front matter 前插入段落；序列化只认第一个节点是 front matter，其它位置的 front matter 节点渲染为空。修复：序列化时无论位置都把它提到文件开头。
24. **只有 front matter 的文件打开后没有地方输入；往返一次多出两个空行。** 修复：解析时补一个空段落，序列化时正文为空不再追加空行。
25. **裸 URL 和邮箱每次保存都变成 `[x](x)`。** marked 自动识别为链接，TipTap 的 Link 固定写成 `[text](href)`。修复：自定义 `MarginLink`，文字和 href 相同（或 `mailto:`+文字）时按原样写出。为此把 `@tiptap/extension-link` 显式加进 `package.json`（它本来就在 lock 树里，`npm ci` 不需要新下载）。
26. **href 含空格的链接保存后重新打开不再是链接**，下次保存还会被转义成 `\[doc](…)`。修复：这种 href 写成 `<…>`。
27. **`&copy;`、`&nbsp;` 等实体被写成 `&amp;copy;`**，渲染出来变成字面文本。TipTap 只解码 `lt/gt/quot/amp` 和数字实体，其余原样进入文本，我们却按"看起来像实体"全部转义。修复：只转义解析器会解码的那几种。
28. **`tidy()` 改动了本应逐字保留的内容：** 原始 HTML 块里的空行被折叠、`&nbsp;` 行被清空；引用块里的代码块（`> ```）和缩进 ≥ 4 的嵌套代码块也被当成普通文本处理。修复：HTML 块的输出用私用区字符 U+E000/U+E001 包起来，`tidy` 跳过其间的行并在最后去掉标记；围栏正则允许任意引用标记和缩进。
29. **查找替换：替换文本包含查询词时（`cat` → `cats`），点 Replace 一直替换同一处，永远走不到下一个。** 修复：替换后跳到替换文本之后的第一个匹配；没有时进入"无当前匹配"状态（计数显示 `N matches`），再按 Replace 不动，按 Next/Previous 才继续。
30. **在 A 标签页打开查找后切到 B 关闭查找栏，回到 A 高亮仍在，并随输入持续刷新。** 修复：切到一个标签页时，若查找栏已关而它还带着查询，清掉。
31. **切换源码模式时光标定位错误**，三种情况：长段落后面跟空段落时光标被拉回前一段 24 个字符处；某段开头 24 个字符在前面段落中间出现过；光标前有 emoji。修复：块定位只接受行首的匹配，空块定位到前一行末尾，字符逐一比较改为按 UTF-16 单元。
32. **在已有段落开头输入 `$$x$$` 会删掉整段。** 输入规则替换的是整个段落。修复：段落里只有公式时才替换整段，否则只替换输入的文本（ProseMirror 会把段落拆开）。
33. **段落行首的块语法不转义**：段落文字以 `# `、`- `、`1. `、`---`、4 个空格开头，或硬换行后一行这样开头，保存后重新打开就变成标题 / 列表 / 分割线 / 代码块。修复：`escapeLineStart` 给这些标记加反斜杠，4 空格的第一个空格写成 `&#32;`。
34. **`a == b` 被保存成 `a \=\= b`。** 只有出现第二个 `==` 才可能构成高亮。修复：文本里少于两个 `==` 时不转义。
35. **导出的 HTML 带编辑器专用标记**：每个普通代码块一个空 `<div class="diagram">`，空文档一个带 `data-placeholder` 的段落。修复：导出时去掉。

## 发现但没有改

- **TipTap 上游 — 有序列表里的代码块每保存一次多一个前导空格**（累积损坏）。`@tiptap/extension-list` 的 `collectOrderedListItems` 计算续行缩进时漏了 `.`/`)` 分隔符的一列（`contentIndent = indentLevel + marker.length + 1`，应为 `+ 2`）。该函数未导出，Margin 这边没有干净的绕法。建议向上游报修并在修复版本发布后升级；在此之前含代码块的编号列表用 `-` 列表或 Native 编辑器更安全。复现：`1. Install:\n   ```sh\n   npm install\n   ```\n` 往返一次。
- **TipTap 上游 — 包着图片的链接丢失**：`[![Build](badge.svg)](https://ci)` 保存后只剩图片。`@tiptap/markdown` 的 `applyMarkToContent` 只给文本节点加 mark。同根因：`**$x$**` 丢粗体。
- **脚注的第二段**（空行加 4 空格缩进）会变成代码块：我们的脚注 tokenizer 只取直接缩进的续行，而 `FootnoteDef` 节点本身只容纳一段。
- Save As 到别的文件夹后，已渲染的图片仍用旧路径（`main.ts` 的 `rename()` 不重绘），重开标签页即正常。
- 源码模式下的大纲会把代码块里的 `# comment` 当成标题（富文本模式不会）。
- `workspace.expanded` 里被删除 / 重命名掉的键不会被清理，只影响 session 文件体积。
- Native 编辑器每次光标移动都做 4–5 次全文扫描（`codeFence`、`MarkdownTable.at`），大文件可能有感，属性能不属错误。
- `NativePasteTests` 在这个沙箱里失败，原因是拿不到系统剪贴板服务（日志：`hiservices-xpcservice` / `Sandbox restriction`），不是代码问题。

## 验证

- `swift test`（需 `--disable-sandbox`，依赖解析在沙箱里要把 scratch 目录放到 `$TMPDIR`）：`MarginCoreTests` 82/82（原 71 + 新 11）；`MarginTests` 14 个中 12 通过，失败的 2 个都是上面说的 `NativePasteTests`。
- `WebEditor`: `node build.mjs --test && node --test 'test/*.test.mjs'` 85/85（原 68 + 新 17）。
- `scripts/build-editor.sh` 已重跑，`Sources/Margin/Resources/Editor/editor.js` 是新产物（CI 会校验它和源码一致）。
- 没有做的：在真实 GUI 里跑（沙箱不能启动 app）；需要弹对话框的路径（13、14、21）只能手测。

## 复查时建议重点看

- `WorkspaceWindowController.trash`：行为从"先删再移除标签页"改成"先关标签页再删"，关标签页时可能弹"保存更改？"。
- 空 `Untitled.md` / 空草稿的删除时机从 `prepareToClose` 挪到 `windowWillClose` 和退出确认之后。
- `markdown.ts`：`escapeLineStart` 对段首 4 空格用 `&#32;`；HTML 块用 U+E000/U+E001 作标记，依赖"正文里不会出现私用区字符"。
- `find.ts`：引入 index 为 -1 的"无当前匹配"状态，计数文案多了 `N matches`。
- `editor.ts`：Link 从 StarterKit 里关掉，改用 `MarginLink`；`package.json` / lock 多了 `@tiptap/extension-link`。
