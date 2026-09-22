# Multi Claude Desktop

Claude Desktop (Windows) を、**ログアウト／ログインなしで複数アカウント同時に使う**ためのツールです。

## 仕組み

ログイン状態はすべて 1 つの user data directory に入っています。別ディレクトリを渡せば、
アカウントごとに独立したインスタンスが**同時に起動したまま**共存します。

```
claude.exe --user-data-dir="%APPDATA%\Claude-work"
```

本体は MSIX パッケージで、パスにバージョン番号が含まれます。アップデートのたびに変わるため
ショートカットに直書きすると壊れますが、`mcd.ps1` は起動のたびに `Get-AppxPackage` で解決します。

## セットアップ

```powershell
cd C:\workspace\multi-claude-desktop

.\mcd.ps1 add work -Label "Claude (仕事)"   # データは %APPDATA%\Claude-work
.\mcd.ps1 launch work                        # 起動してログイン

.\mcd.ps1 tray                               # トレイ常駐
.\mcd.ps1 autostart                          # サインイン時に自動起動
```

`default` プロファイルは既存の `%APPDATA%\Claude` を指し、**今の環境には手を加えません**。

> 実行ポリシーで弾かれる場合は `powershell -ExecutionPolicy Bypass -File .\mcd.ps1 list` で。

## コマンド

| コマンド | 説明 |
| --- | --- |
| `list` | プロファイル一覧と状態 |
| `add <name> [-Label <text>] [-DataDir <path>]` | プロファイルを登録 |
| `launch <name>` | 起動（タスクバー識別子とアイコンも付与） |
| `stamp <name>｜-All` | 起動中のウィンドウに識別子とアイコンを付け直す |
| `icon [<name> <image> [-Full]｜<name> -Clear]` | プロファイル別アイコン |
| `share <name>｜-All` / `unshare` | セッション一覧の同期を ON/OFF |
| `sync-sessions` | 同期を 1 回実行 |
| `sync-config <from> <to>` | MCP 設定 (`claude_desktop_config.json`) をコピー |
| `tray` / `autostart [on｜off｜status]` | トレイ常駐 / 自動起動 |
| `open <name>` / `remove <name>` / `where` | データフォルダを開く / 削除 / exe パス |

## タスクトレイ

トレイから起動・共有の切り替えができます。常駐している理由は 2 つあります。

**ウィンドウの監視。** タスクバー識別子 (AUMID) とアイコンは**ウィンドウごとの属性**で、
Claude Desktop がウィンドウを作り直すたびに失われます。トレイが 3 秒間隔で付け直します。

**セッション一覧の同期。** 下記。

## セッション一覧の共有

Claude Code のセッションは 2 つに分かれて保存されています。

```
会話の実体   %USERPROFILE%\.claude\projects\<cwd>\<cliSessionId>.jsonl   ← 元から全プロファイル共有
一覧の索引   <dataDir>\claude-code-sessions\<accountId>\<orgId>\local_<id>.json
```

**会話の実体は最初から共有**されています。アカウントごとに一覧が違うのは索引のせいだけなので、
トレイが索引エントリをプロファイル間でコピーします。

```powershell
.\mcd.ps1 share work     # プロファイル単位でオプトイン（既定は共有しない）
```

同期のルールは 4 つだけです。

- **`local_<uuid>.json` だけ。** UUID 名なので衝突しません
- **mtime が最新のコピーが勝ち**、それを全プロファイルに配ります
- **削除はしない。** `deleted_` マーカーがあるものは配りません（ゾンビ復活の防止）
- **`archived-sessions.idx` と `scheduled-tasks.json` は触りません。** 固定名の共有状態なので

上書きされる側は `%LOCALAPPDATA%\multi-claude-desktop\session-index-backup\` に 1 世代退避します。

> **同じセッションを 2 つのプロファイルで同時に開かないでください。** 両方が同じ transcript に
> 追記して壊れます。違うセッションの同時利用は問題ありません。

### ディレクトリリンクは使えません

最初はジャンクションで索引を共有しようとしましたが、**Claude Desktop が拒否します**。
`app.asar` に `ERR_SAFE_FS_SYMLINK` (`Refusing to follow symlink under root`) と
`ERR_SAFE_FS_ESCAPE` (`Path escapes root`) があり、データディレクトリ配下のリパースポイントを
意図的に辿りません。**黙って索引の書き込みを止める**ので気付きにくい失敗をします。
シンボリックリンクも同じです。コピー同期はこれを避けるための方式です。

## プロファイル別アイコン

`profiles.json` に画像のパスを書くだけです。png / jpg / bmp / gif / ico。

```json
{ "name": "work", "icon": "icons\\work.png", "iconStyle": "overlay" }
```

| `iconStyle` | 見た目 |
| --- | --- |
| `overlay`（既定） | Claude のアイコンはそのまま、**タスクバーのオーバーレイ枠**に表示（Chrome のプロファイルアイコンと同じ `ITaskbarList3::SetOverlayIcon`） |
| `badge` | Claude のアイコンの角に丸く合成 |
| `full` | 画像だけ |

`badge` は `iconBase` / `iconBadgePos` / `iconBadgeScale` / `iconBaseScale` で調整できます。
プロファイル内に書けば個別、トップレベルなら全体の既定です。

画像は 16〜256px のマルチサイズ .ico に変換して `icons\cache\` に置きます。ファイル名にハッシュが
入るのは、エクスプローラーがタスクバーのアイコンを**パス単位でキャッシュ**するためです。

> overlay はトレイが生きている間だけ表示されます（オーバーレイ枠はプロセスに紐付くため）。

## タスクバーの分離

MSIX パッケージなので、`--user-data-dir` を変えても全インスタンスが同じ AUMID を継承して
1 つのボタンにまとまります。そこでプロファイル固有の AUMID をウィンドウに書き込みます。

タスクバーの**ボタンのアイコンと名前**はウィンドウではなく、**同じ AUMID を持つスタートメニューの
ショートカット**から取られます。そのため `%APPDATA%\Microsoft\Windows\Start Menu\Programs\
Multi Claude Desktop\` に登録用の `.lnk` を自動生成します（`launch` / `stamp` / `icon` とトレイが
作成・更新、`remove` で削除）。ウィンドウアイコンが効くのはホバー時のサムネイルと Alt+Tab までです。

`stock: true` のプロファイルだけは既定の AUMID を保ちます。既存のピン留めを壊さないためです。

## ファイル構成

| ファイル | 役割 |
| --- | --- |
| `mcd.ps1` | 本体 |
| `mcd-tray.ps1` | トレイ常駐。`mcd.ps1` をドットソースして関数を再利用 |
| `profiles.json` | プロファイル定義（自動生成、gitignore） |
| `icons/` | アイコンとその変換結果（自動生成 or 各自の画像、gitignore） |
| `run-hidden.vbs` | 黒い窓を出さないためのラッパー（自動生成） |

トレイアイコンはコードで描画するのでバイナリ同梱は不要です。

## 既知の制約

- `claude://` リンクは常に既定インストール側が反応します。プロトコルハンドラは MSIX パッケージに
  登録されており、プロファイル別に分けられません
- MCP 設定はプロファイルごとに独立です（`sync-config` でコピー可）
- アカウント同期の skill は共通化できません。`~/.claude/skills/` の自作 skill や `commands/`、
  `CLAUDE.md`、`settings.json` は元から全プロファイル共通です
- ディスク使用量はプロファイル数だけ増えます（1 つあたり数百 MB）
- アプリのアップデートは MSIX 単位なので全プロファイルに同時に反映されます

## 参考

- [Claude Windowsアプリで複数アカウントを同時に使う (Qiita)](https://qiita.com/vivinko/items/bdda0fcdeb53e45e5471)
