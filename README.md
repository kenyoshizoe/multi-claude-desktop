# Multi Claude Desktop

Claude Desktop (Windows) を、**ログアウト／ログインなしで複数アカウント同時に使う**ためのツールです。

## 仕組み

Claude Desktop は Electron アプリなので、ログイン状態（Cookie・Local Storage・セッション）は
すべて 1 つの **user data directory** に入っています。既定値は `%APPDATA%\Claude` です。

```
claude.exe --user-data-dir="C:\Users\<you>\AppData\Roaming\Claude-work"
```

このように別ディレクトリを渡すと、アカウントごとに独立したインスタンスが立ち上がり、
**同時に起動したままにできます**。切り替えではなく共存です。

本体 (`claude.exe`) は MSIX パッケージとしてインストールされており、パスにバージョン番号が
含まれます。

```
C:\Program Files\WindowsApps\Claude_<version>_x64__pzs8sxrjxfjjc\app\claude.exe
```

アップデートのたびにこのパスが変わるため、**ショートカットに exe を直書きすると必ず壊れます**。
`mcd.ps1` は起動のたびに `Get-AppxPackage` でパスを解決するので、アップデートしても壊れません。

## セットアップ

```powershell
cd C:\workspace\multi-claude-desktop

# プロファイルを登録（データは %APPDATA%\Claude-<name> に作られる）
.\mcd.ps1 add work     -Label "Claude (仕事)"
.\mcd.ps1 add personal -Label "Claude (個人)"

# 1 つずつ起動して、それぞれのアカウントでログインする
.\mcd.ps1 launch work
.\mcd.ps1 launch personal

# タスクトレイに常駐させ、サインイン時に自動起動させる
.\mcd.ps1 tray
.\mcd.ps1 autostart
```

初回だけ各プロファイルでログインすれば、以降はトレイアイコンから直接そのアカウントで開きます。

> 実行ポリシーで弾かれる場合は
> `powershell -ExecutionPolicy Bypass -File .\mcd.ps1 list`
> のように呼ぶか、`Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` を設定してください。
> 自動起動用のショートカットは `-ExecutionPolicy Bypass` 付きで呼ぶので影響を受けません。

## コマンド

| コマンド | 説明 |
| --- | --- |
| `.\mcd.ps1 list` | プロファイル一覧・データディレクトリ・起動中かどうかを表示 |
| `.\mcd.ps1 add <name> [-Label "表示名"] [-DataDir <path>]` | プロファイルを登録 |
| `.\mcd.ps1 launch <name> [-NoStamp]` | そのプロファイルで Claude Desktop を起動（タスクバー識別子も付与） |
| `.\mcd.ps1 stamp <name>｜-All` | 起動中のウィンドウにタスクバー識別子とアイコンを付け直す |
| `.\mcd.ps1 sync-config <from> <to>` | MCP 設定 (`claude_desktop_config.json`) をコピー |
| `.\mcd.ps1 share <name>｜-All [-Force]` | そのプロファイルの Claude Code セッション一覧を共有ストアに繋ぐ |
| `.\mcd.ps1 unshare <name>｜-All [-Force]` | 共有を解除（一覧は専用のコピーとして残る） |
| `.\mcd.ps1 tray` | タスクトレイ常駐。起動と共有 ON/OFF をメニューから操作 |
| `.\mcd.ps1 autostart [on｜off｜status]` | トレイをサインイン時に自動起動（既定は `on`） |
| `.\mcd.ps1 icon [<name> <image>｜<name> -Clear]` | プロファイルごとのアイコンを設定・解除。引数なしで一覧 |
| `.\mcd.ps1 open <name>` | データディレクトリをエクスプローラーで開く |
| `.\mcd.ps1 remove <name> [-DeleteData] [-Force]` | プロファイルを削除 |
| `.\mcd.ps1 where` | 解決された `claude.exe` のパスを表示 |

## ファイル構成

| ファイル | 役割 |
| --- | --- |
| `mcd.ps1` | 本体。コマンドラインはこれ 1 つで完結します |
| `mcd-tray.ps1` | タスクトレイ常駐版。`mcd.ps1` をドットソースして関数を再利用します |
| `profiles.json` | プロファイル定義。初回実行時に自動生成 |
| `run-hidden.vbs` | 黒い窓を出さずに起動するためのラッパー（自動生成） |
| `icons/claude.ico` | 既定アイコン。アプリの PNG から自動生成 |
| `icons/mcd-tray.ico` | このツール自身のアイコン。コードで描画して自動生成 |
| `icons/cache/` | プロファイル別アイコンの変換結果（自動生成） |

`profiles.json` の `default` プロファイルは既存の `%APPDATA%\Claude` を指しており、
**今使っている環境には一切手を加えません**。

## Claude Code のセッションを共有する

「どのアカウントで開いても同じセッション一覧が見えて、そのまま再開できる」状態にできます。
共有するかどうかは**プロファイルごとに選べます**（既定はどれも共有しません）。

```powershell
# それぞれ一度ログインを済ませ、アプリを閉じてから
.\mcd.ps1 share default
.\mcd.ps1 share work

.\mcd.ps1 list        # Sessions 列が linked になる
.\mcd.ps1 unshare work   # このアカウントだけ元の独立状態に戻す
```

### なぜこれで足りるのか

Claude Code のセッションは 2 つに分かれて保存されています。

```
会話の実体   %USERPROFILE%\.claude\projects\<cwd を変換した名前>\<cliSessionId>.jsonl
一覧の索引   <dataDir>\claude-code-sessions\<accountId>\<orgId>\local_<id>.json
```

**会話の実体はもともと全プロファイル共有**です。`%USERPROFILE%` の下にあり `--user-data-dir` の
影響を受けません。プロファイルごとに分かれているのは索引のほうだけで、中身は
`cliSessionId` / `cwd` / `title` / `model` といった数百バイトのメタデータです。

つまり**アカウントごとに一覧が違って見える原因は索引 1 箇所だけ**なので、
`share` はこのディレクトリを共有ストアへのディレクトリジャンクションに差し替えます。

```
%APPDATA%\Claude-shared\claude-code-sessions\      <- 共有ストア
   ^                              ^
   |                              |
Claude\claude-code-sessions\<accountId>\<orgId>            --> junction
Claude-work\claude-code-sessions\<accountId>\<orgId>       --> junction
```

ジャンクションはシンボリックリンクと違い**管理者権限なしで作成できます**。
共有ストアの場所は `profiles.json` の `sharedSessionsDir` で変更できます。

### 挙動

- 片方で始めたセッションは、もう片方のウィンドウにすぐ現れてそのまま再開できます。
- 初回の `share` 時、そのプロファイルが持っていた索引は共有ストアに**マージ**されます
  （ファイル名が `local_<uuid>` なので衝突しません）。元の索引は
  `<orgId>.mcd-bak-<日時>` として残り、新しい順に 3 つまで保持されます。
- `unshare` すると、共有中に見えていた一覧を**そのプロファイル専用のコピーとして書き戻します**。
  共有ストア自体には手を付けないので、他のプロファイルは影響を受けません。
- まだログインしていないプロファイルを `share` した場合は `pending` になり、
  次回 `launch` 時に自動でリンクされます（`accountId` / `orgId` はログイン時に作られるため）。

### 注意

- **共有・解除はアプリを閉じてから**行ってください。起動中はディレクトリを掴んでいます。
  `-Force` で無視できますが推奨しません。
- 索引ディレクトリには `scheduled-tasks.json` も入っているため、**スケジュール実行の定義も
  共有されます**。
- 索引の `enabledMcpTools` はアカウント固有のコネクタ UUID をキーにしているので、
  他アカウント由来のセッションでは MCP ツールの ON/OFF 状態が一致しないことがあります。

## タスクトレイ常駐

```powershell
.\mcd.ps1 tray
```

トレイアイコンを右クリックすると、プロファイルの起動と、
**どのアカウントを共有対象にするかのチェック切り替え**ができます。

```
Claude               (running, linked)
Claude (Work)        (linked)
----
Share Claude Code sessions >
    [x] Claude
    [x] Claude (Work)
    ----
    Open the shared session folder
Open data folder >
----
Re-apply icons and taskbar names
[x] Start with Windows
Edit profiles.json
Exit
```

トレイアイコンは**このツール自身のマーク**（Claude オレンジの角丸バー 3 本＝複数の Claude
ウィンドウ）です。Claude 本体のアイコンと紛れないようにするためで、`icons/` は
バージョン管理外なので**バイナリを同梱せずコードで描画**しています
（`Initialize-TrayIcon`）。自動起動用ショートカットにも同じものを付けるので、
スタートアップ フォルダでも見分けられます。

起動は `mcd.ps1 launch` を別プロセスで呼びます（タスクバー識別子の付与に最大 45 秒
かかることがあり、メニューを固めないため）。共有の切り替えは同一プロセス内で即時に
処理されます。トレイはミューテックスで一つだけに制限され、二重起動しません。

### ウィンドウの監視

AUMID とアイコンは**ウィンドウごとの属性**で、Claude Desktop がウィンドウを作り直すたびに
失われます。アプリはリロードや新規ウィンドウで実際にこれをやるので、`stamp` を一度打っただけでは
しばらくすると「効いていない」状態に戻ります。

そこでトレイは 3 秒間隔で、未処理のウィンドウにタスクバー識別子とアイコンを付け直します。

- 軽量化のため、まず `Get-Process` で claude.exe の PID 集合だけを見ます。集合と
  `profiles.json` の更新日時が変わらなければ、`Win32_Process` の問い合わせは行いません
- 適用済みのウィンドウは `hwnd -> "<aumid>|<icon>"` で記録し、変化が無ければ何もしません
- `profiles.json` を編集するとこの記録を破棄して全ウィンドウに付け直します
  （アイコンを差し替えたら自動で反映される、ということです）
- 閉じたウィンドウの記録は毎回掃除します

メニューの **Re-apply icons and taskbar names** で手動実行もできます。

`mcd-tray.ps1` は `mcd.ps1` をドットソースして関数をそのまま使うので、共有ロジックの
実装は 1 箇所だけです。ログイン中のプロファイルを切り替えようとした場合はバルーンで
警告し、何もしません。

### 自動起動

```powershell
.\mcd.ps1 autostart          # サインイン時に自動起動
.\mcd.ps1 autostart status
.\mcd.ps1 autostart off
```

スタートアップフォルダ (`shell:startup`) に
`Multi Claude Desktop (tray).lnk` を置くだけの実装です。タスクスケジューラを使わないので
管理者権限は不要で、エクスプローラーや「タスク マネージャー → スタートアップ アプリ」から
ユーザー自身が確認・無効化できます。トレイメニューの **Start with Windows** でも同じ操作が
できます。

ショートカットは**このフォルダ (`C:\workspace\multi-claude-desktop`) を指します**。
移動・リネームすると自動起動が壊れるので、その場合は移動先で `.\mcd.ps1 autostart` を
実行し直してください（`autostart status` は別の場所を指す古いショートカットを検出して警告します）。

Claude Desktop 本体を自動起動したいわけではない点に注意してください。常駐するのは
トレイアイコンだけで、どのプロファイルを開くかはメニューから選びます。

## プロファイルごとのアイコン

`profiles.json` の `icon` に**画像ファイルのパスを直接書くだけ**です。

```json
{
  "name": "work",
  "label": "Claude (Work)",
  "dataDir": "C:\\Users\\you\\AppData\\Roaming\\Claude-work",
  "icon": "icons\\work.png",
  "iconStyle": "badge"
}
```

- png / jpg / bmp / gif / ico を受け付けます
- 相対パスは**リポジトリ基準**。絶対パスでどこを指しても構いません
- ファイルが無い場合は既定のアイコンにフォールバックし、`icon` コマンドが `MISSING` と表示します

> `icons/` は `.gitignore` 対象です。中身は自動生成物か、あなたが選んだ画像なので、
> リポジトリには含まれません。アイコンを設定しなくてもツールは動きます
> （Claude 本体のアイコンがそのまま使われます）。

### 2 つのスタイル

| `iconStyle` | 見た目 |
| --- | --- |
| `overlay`（既定） | **Claude のアイコンには触れず、タスクバーのオーバーレイ枠に指定画像を出します**（Chrome のプロファイルアイコンと同じ仕組み） |
| `badge` | 指定画像を Claude のアイコンに丸く合成します |
| `full` | 指定画像だけを使います |

### overlay

Windows のタスクバーには、未読バッジなどに使われる**オーバーレイ枠**があります
（`ITaskbarList3::SetOverlayIcon`）。Chrome のプロファイルアイコンはこれです。

アイコン本体を作り替えないので Claude の絵がそのまま残り、隅に小さく重なります。
位置とサイズは Windows が決めるため、こちら側の調整項目はありません。

オーバーレイ用の画像は**白い円で塗りつぶした上に**乗せます。透過 png をそのまま渡すと
タスクバーの地に溶けてしまうためです。

トレイメニューの行には、overlay でも**指定画像のほう**を出します。ウィンドウのアイコンは
素の Claude のままですが、メニューは見分けるための一覧なので、そこで全部同じ絵が並んでも
意味がないためです。

- オーバーレイは**設定したプロセスが生きている間だけ**表示されます。トレイが常駐して
  維持するので、`autostart` を有効にしておいてください
- タスクバーを「小さいボタン」にしていると Windows がオーバーレイを描きません

`badge` は Chrome のプロファイルアイコンと同じ発想で、既定では**右上**に丸く重ねます。
下地に白い円を敷いて元絵の上でも潰れないようにし、細い白リングで輪郭を分離しています。
画像はアスペクト比を保ったまま円内に収めます。

### バッジの調整

| キー | 既定 | 意味 |
| --- | --- | --- |
| `iconBadgePos` | `top-right` | `top-right` / `bottom-right` / `top-left` / `bottom-left` |
| `iconBadgeScale` | `0.52` | バッジの直径（アイコン全体に対する比） |
| `iconBadgePad` | `0.03` | 角からの余白。`0` にすると完全に隅へ寄ります |
| `iconBaseScale` | `1.0` | 下地の縮尺。余白の無い画像を下地にすると素のアイコンより重く見えるので、`0.85`〜`0.9` にすると馴染みます |

いずれも `iconBase` と同じく、プロファイル内なら個別、トップレベルなら全体の既定です。

```json
{
  "iconBase": "icons\\claude-mark.png",
  "iconBadgePos": "top-right",
  "iconBadgeScale": 0.45,
  "profiles": [ ... ]
}
```

`badge` の下地は既定で**アプリ本来のアイコン**です。つまり素のプロファイルと同じ絵の上に
バッジが乗ります。別の画像にしたい場合だけ `iconBase` を書きます。プロファイル内なら個別、
トップレベルなら全プロファイル共通の既定です。

```json
{
  "iconBase": "icons\\claude-mark.png",
  "profiles": [ ... ]
}
```

省略した場合は **`claude.exe` に埋め込まれたアイコン**を使います（`PrivateExtractIcons` で 256px を
取り出して `icons\cache\app-<hash>.png` にキャッシュ。アプリ更新でパスが変わり自動で取り直されます）。

Claude のアイコンはパッケージ内に 2 種類あります。

| | 放射 | 使われ方 |
| --- | --- | --- |
| `assets\Square44x44Logo.png` | 細い | `AppxManifest.xml` が指定する公式ロゴ |
| **`claude.exe` 内蔵** | **太い** | `iconBase` 未設定時の下地。Wikimedia の Claude シンボルと同じ意匠 |

`icon.png` や `Square150x150Logo.png` は前者と同じ細い方です。

コマンドからも設定できます。画像を `icons\` にコピーして `icon` に書き込むだけなので、
結果は JSON を手で書いた場合と同じです。

```powershell
.\mcd.ps1 icon work C:\path\to\blue.png          # バッジ（既定）
.\mcd.ps1 icon work C:\path\to\blue.png -Full    # 画像だけ
.\mcd.ps1 icon                      # 一覧
.\mcd.ps1 icon work -Clear    # 既定の Claude アイコンに戻す
```

### 変換とキャッシュ

Windows のタスクバー・ショートカット・ピン留めはいずれも `.ico` しか受け付けません。
そこで `.ico` 以外を指定した場合は
**16・24・32・48・64・128・256 px のマルチサイズ .ico に変換**して
`icons\cache\<name>.ico` に置きます。Windows は用途ごとに違うサイズを要求するため、
単一サイズだとどこかで必ずぼやけます。

変換は**必要になったときだけ**走ります。出力名にはソース画像のパス・サイズ・更新日時から作った
ハッシュが入ります（`icons\cache\work-8f6b11e9.ico`）。
エクスプローラーはタスクバーのアイコンを**パス単位でキャッシュ**するため、同じ名前で中身だけ
差し替えても古い絵が出続けるからです。画像を描き直せばパスが変わり、確実に読み直されます。
ハッシュには `iconStyle` と下地の Claude ロゴのパスも含めているので、スタイル変更やアプリの
アップデートでも作り直されます。古い変換結果は自動で掃除します。

正方形でない画像はアスペクト比を保って中央に配置します（引き伸ばしません）。

> 16〜64 px は従来の DIB 形式、128 px 以上は PNG 圧縮で書き出しています。
> 小サイズを PNG にすると `System.Drawing` の `Icon.ToBitmap()` が読めず、
> トレイメニューにアイコンが出なくなるためです。

### どこに反映されるか

| 対象 | 反映される | 仕組み |
| --- | --- | --- |
| **起動中のタスクバーボタン・Alt+Tab** | する | ウィンドウに `WM_SETICON` を送る |
| ピン留めしたボタン | する | AUMID の `RelaunchIconResource` |
| トレイメニューの各行 | する | 16px を読み込んで表示 |

**アイコンを設定していないプロファイルには何も上書きしません。** `RelaunchIconResource` は
明示的に空へ戻すので、Claude 本体のアイコンがそのまま出ます。

### タスクバーのボタンだけ別扱い

ウィンドウアイコン (`WM_SETICON`) が効くのは **ホバー時のサムネイルと Alt+Tab** までです。
**タスクバーのボタン**はそこを見ておらず、ウィンドウの AUMID を手がかりに
**同じ AUMID が書かれたスタートメニューのショートカット**を探して、その
アイコンと名前を使います。見つからなければパッケージ本体のアイコンにフォールバックします。

そのため `mcd.ps1` は AUMID ごとに登録用のショートカットを自動で作ります。

```
%APPDATA%\Microsoft\Windows\Start Menu\Programs\Multi Claude Desktop\
    Claude (Personal).lnk   AUMID=Anthropic.Claude.personal   icon=claude.exe,0
    Claude (Work).lnk       AUMID=Anthropic.Claude.work       icon=cache\work-<hash>.ico,0
```

これは以前あった `shortcut` コマンドとは目的が違います。ユーザーが作るものではなく、
`launch` / `stamp` / `icon` とトレイが**自動で作成・更新**します。内容に変化が無ければ
書き換えません。アイコン未設定のプロファイルは `claude.exe` を指すので、本体と同じ絵になります。
`remove` で削除されます。

クリックすればそのプロファイルが起動しますが、それは副産物です。

`stock: true` のプロファイルは登録しません。パッケージ既定の AUMID を保つためです。

`icon` 実行時に**起動中のインスタンスがあれば即座に反映**します。
**Claude Desktop はウィンドウを頻繁に作り直す**（リロード、新規ウィンドウ、サインイン）ため、
一度付けたアイコンはそのウィンドウと一緒に消えます。トレイが 3 秒おきに未処理のウィンドウを
拾って付け直すので、常駐させておけば気にする必要はありません。
トレイを使わない場合は `.\mcd.ps1 stamp -All` を都度実行してください。

`stock: true` のプロファイルもアイコンだけは変更できます。AUMID には触れないので、
既存のピン留めはそのまま維持されます。

> アプリのアイコン自体を差し替えているわけではなく、**ウィンドウのアイコンを上書き**しています。
> Claude Desktop 側が再設定した場合もトレイが数秒で付け直します。

## 設定はどこまで共有されるか

Claude Code の設定の大半は `%USERPROFILE%\.claude\` にあり、`--user-data-dir` の外なので
**最初から全プロファイル共通**です。

| 共通（`%USERPROFILE%\.claude\`） | 内容 |
| --- | --- |
| `skills\` | 自作 skill。そのまま全アカウントで使えます |
| `commands\` | スラッシュコマンド |
| `CLAUDE.md` | グローバル指示 |
| `settings.json` | 応答言語、hooks など |
| `projects\` | 会話の実体（transcript） |
| `plugins\` | インストール済みプラグイン、マーケットプレイス |

| プロファイルごと（`<dataDir>`） | 内容 |
| --- | --- |
| ログイン状態 | Cookie / Local Storage |
| `claude_desktop_config.json` | MCP サーバー設定 → `sync-config` でコピー |
| `claude-code-sessions\` | セッション一覧の索引 → `share` で共有 |
| `local-agent-mode-sessions\skills-plugin\` | **アカウント同期 skill** のキャッシュ |

アカウントに紐付いてクラウドから配られる skill（`docx`, `pdf`, `pptx` など）だけは
アカウントごとに別物になります。`%USERPROFILE%\.claude\skills\synced\<orgId>_<accountId>\` に
分かれて置かれるため、共通化はできません。

## タスクバーを分ける仕組み

Windows のタスクバーは **AppUserModelID (AUMID)** でウィンドウをグループ化します。
Claude Desktop は MSIX パッケージなので、`--user-data-dir` を変えて起動しても
全インスタンスがパッケージの AUMID `Claude_pzs8sxrjxfjjc!Claude` を継承し、
既定では 1 つのボタンに統合されてしまいます。

そこで `mcd.ps1` は起動直後にウィンドウを捕まえ、`SHGetPropertyStoreForWindow` 経由で
プロファイル固有の AUMID を書き込みます。

| プロパティ | 設定値 | 効果 |
| --- | --- | --- |
| `System.AppUserModel.ID` | `Anthropic.Claude.<name>` | タスクバーのグループを分離 |
| `System.AppUserModel.RelaunchCommand` | `mcd.ps1 launch <name>` | ピン留め時に同じプロファイルで再起動 |
| `System.AppUserModel.RelaunchDisplayNameResource` | プロファイルの `label` | ボタン名が「Claude (仕事)」等になる |
| `System.AppUserModel.RelaunchIconResource` | `icons\claude.ico` | ピン留め時のアイコン |

`RelaunchCommand` を書き込んであるので、タスクバーのボタンを右クリックしてピン留めすると、
**そのプロファイルで起動し直すピン**になります。

`default` プロファイルだけは意図的にパッケージの AUMID のままにしてあります。
既存のピン留めをそのまま使い続けられるようにするためです。

AUMID を変えたくない場合は `.\mcd.ps1 launch <name> -NoStamp` で無効化できます。
`profiles.json` に `"aumid": "好きな文字列"` を書けば ID 自体も変更できます。

## 注意点・既知の制約

- **MCP 設定はプロファイルごとに独立**します。`claude_desktop_config.json` はデータディレクトリ内に
  あるため、新しいプロファイルは MCP サーバーが空の状態から始まります。`sync-config` でコピーできます
  （上書き時は自動でバックアップを取ります）。
- **Claude Code のセッション一覧は既定では独立**です。共有したい場合は `share` を使ってください
  （上記「Claude Code のセッションを共有する」）。会話の実体だけは最初から共有されています。
- Cowork／エージェントモード (`local-agent-mode-sessions`) と git チェックポイント (`git-shadow`) は
  共有対象に**含めていません**。前者はセッション内にアカウント固有の情報が埋まっているためです。
- `claude://` プロトコルリンクを開くと、常に **既定インストール（`default` プロファイル）側**が
  反応します。プロトコルハンドラは MSIX パッケージに登録されており、プロファイル別に
  分けることはできません。
- **AUMID とアイコンはウィンドウ単位**なので、アプリがウィンドウを作り直すと消えます。
  トレイがこれを監視して付け直します。トレイを常駐させない場合は `.\mcd.ps1 stamp -All` が必要です。
- ディスク使用量はプロファイル数だけ増えます（キャッシュ含めて 1 つあたり数百 MB 程度）。
- アプリのアップデートは MSIX パッケージ単位なので、全プロファイルに同時に反映されます。

## 参考

- [Claude Windowsアプリで複数アカウントを同時に使う (Qiita)](https://qiita.com/vivinko/items/bdda0fcdeb53e45e5471)
