# 対話オプションの定義方針

この文書は、Rapid Rails Templateへ対話的な選択肢を追加するときの記録形式と設計規則を定義します。固定技術スタックは[採用技術とセットアップ要件](stack.md)を参照してください。

## 必須項目

各オプションは、次の項目を文書化します。

| 項目 | 内容 |
| --- | --- |
| 識別子 | `snake_case`の一意な内部識別子 |
| 質問文 | 利用者へ表示する日本語の質問 |
| 選択肢 | 選択可能な値と、それぞれの意味 |
| 既定値 | 明示的な既定値。既定値を持たない場合はその理由 |
| 表示条件 | 先に収集した回答に基づく質問の表示条件 |
| 影響する処理 | 実行計画へ追加または除外するstep |

## 記録テンプレート

新しいオプションは、次の形式でこの文書へ追加します。

```markdown
## `<option_id>`

- 質問文:
- 選択肢:
- 既定値:
- 表示条件:
- 影響する処理:
```

## 設計規則

- RailsアプリIDと表示用アプリ名の自由入力には`gum` 0.3.2の`Gum.input`、対話的な選択には`Gum.choose`、最終確認には`Gum.confirm`を使用する。標準入力を直接読む独自UIや代替UIは持たない。
- 各質問は仕様上の既定値をGumの選択済み項目として渡し、Gumが返した選択肢だけを回答として扱う。選択をキャンセルした場合は生成を開始せず終了する。
- 各オプションは、識別子の`_`を`-`に変換したCLI引数`--OPTION=VALUE`で個別に指定できる。
- CLI引数で指定した回答は再質問せず、未指定の適用可能な項目だけを依存順に質問する。
- すべての適用可能な項目がCLI引数で確定済みの場合は、対話と最終承認を行わず実行計画を表示して開始する。
- すべての適用可能な質問は、`rails new`や一時ファイル作成を開始する前に完了させる。
- 質問中は後続質問の表示条件だけを評価し、対話UI用のGum実行可能ファイル以外の外部command、Gem追加、step構築、file actionを実行しない。
- 全質問の完了後に回答を正規化・検証し、実行開始前に変更不能な設定として確定する。
- 表示条件は、それ以前に確定した回答だけを参照する。
- 質問の依存関係は循環を許さない。有向非巡回グラフとして解決可能な順序を持たせる。
- 質問を表示しなかった場合の値を暗黙に推測しない。必要なら仕様として既定値を定義する。
- 選択肢の追加時に、実行予定へ現れる説明と対象stepを同時に定義する。
- 外部コマンドの有無や処理失敗を理由に、別の選択肢へ自動的に切り替えない。
- 対応範囲外のRailsまたはRuby向け選択肢を追加しない。

## RailsアプリID

- CLI引数: `--app-id=ID`
- 質問文: RailsアプリIDを入力してください。
- 初期値: `APP_PATH`のbasename
- 表示条件: `--app-id`が未指定の場合
- 影響する処理: `rails new`へ単一引数`--name=ID`として渡す

RailsアプリIDは有限選択の設定値とは分離して扱います。キャンセルまたは空入力は生成開始前に拒否し、Rails固有の正規化と妥当性判定は対象versionのRails 8.1へ委ねます。旧`--name`は受け付けず、互換aliasも追加しません。

## 表示用アプリ名

- CLI引数: `--app-name=NAME`
- 質問文: 表示用アプリ名を入力してください。
- 初期値: 確定済みのRailsアプリID
- 表示条件: `--app-name`が未指定の場合
- 影響する処理: Application Identity、title、header、footer、PWA manifest、OGP、mailer、SIWE、Web Push、固定ページseed

表示用アプリ名はRails generatorへ渡しません。CLI引数と`Gum.input`の結果は前後空白を除去し、空文字、空白のみ、キャンセルを生成開始前に拒否します。内部の空白、Unicode、shell metacharacterは保持し、実行計画とJSON payloadで単一値として扱います。

## 既定locale

- CLI引数: `--default-locale=ja|en`
- 質問文: 既定localeを選択してください。
- 既定値: `ja`
- 表示条件: 常時
- 影響する処理: `config.i18n.default_locale`、Application Identity、生成locale、request境界、PWA manifest、mailer、SIWE、Web Push、固定ページseed

生成アプリは`ja`と`en`だけをavailable localeとし、選択値を全requestとrequest外処理の既定localeにします。Accept-Language、request parameter、UserやAccountSettingへの保存、locale切替UIは生成しません。locale fallbackは無効にし、別言語や直書き文字列による欠落補完を行いません。

## 質問順序

質問は次の順序で行います。後続の表示条件と`Auto`判定は、前に確定した回答だけを参照します。

1. RailsアプリID
2. 表示用アプリ名
3. PWAを使うか
4. PWAでWeb Pushを使うか
5. ジョブ管理を使うか（Web Pushを使わない場合）
6. 管理者向けジョブ運用画面を使うか（Solid Queueを使う場合）
7. 管理者向け運用タスクを使うか（Solid Queueを使う場合）
8. Solid Cacheを使うか
9. アカウント管理方法
10. プロフィール機能
11. 画像配信方式
12. API機能を有効にするか
13. Action Cableを使うか
14. メール機能
15. デプロイ方法
16. 既定locale

この順序で適用可能な質問をすべて完了するまで、実行予定の確認へ進みません。表示条件を満たさない質問は利用者へ表示せず、全質問完了後の正規化で仕様どおりの値を設定します。

## 最終確認

全質問の完了後に、次の順序で最終確認内容を構築します。

1. 未回答、無効値、選択肢間の矛盾を検証する。
2. `Auto`と非適用項目を実効値へ正規化する。
3. RailsアプリID、表示用アプリ名、`rails new`のgenerator option、Gem、step、生成物、production processを確定する。
4. RailsアプリID、表示用アプリ名、質問時の回答、実効値、解決理由、実行予定を一覧表示する。
5. 利用者へ一度だけ最終承認を求める。

最終承認は既定値を拒否とする`Gum.confirm`で行います。承認されなければ副作用なしで終了します。承認後は回答、実効値、実行順序を変更せず、追加質問も行いません。

## `pwa`

- CLI引数: `--pwa=use|skip`
- 質問文: PWAを使用しますか？
- 選択肢: `use`、`skip`
- 既定値: `skip`
- 表示条件: 常に表示する
- 影響する処理: PWA manifest、service worker、関連routeの有効化と無効時のstub取扱い

Rails 8.1にはPWA専用の`--skip-pwa`がなく、PWA用stubが標準生成されます。`use`時はRails標準の`Rails::PwaController`へmanifestとService Workerのrouteを接続し、Application Identityの表示用アプリ名と既定locale、標準icon、theme色、`standalone`表示を持つmanifestを決定的に生成します。application layoutへmanifest linkとtheme-colorを追加し、bodyへ接続したStimulus controllerが`/service-worker`をscope `/`で登録します。Service WorkerはWeb PushのJSON payloadを表示し、notification click時は同一originの既存windowを対象pathへ遷移させてfocusします。

`skip`時もRails標準stubは残しますが、route、manifest link、theme-color、Service Worker登録controllerは有効化しません。存在しないgenerator optionや曖昧な文字列編集では処理しません。

## `web_push`

- CLI引数: `--web-push=use|skip`
- 質問文: PWAでWeb Pushを使用しますか？
- 選択肢: `use`、`skip`
- 既定値: `skip`
- 表示条件: `pwa == use`
- 影響する処理: `use`の場合だけ`web-push ~> 3.1`、購読model、認証済みHTTP API、送信service/job、独立した通知設定ページを生成する

`pwa == skip`の場合は質問せず、値を`skip`へ正規化します。ただしCLIで`--pwa=skip --web-push=use`を明示した場合は、矛盾を生成開始前に拒否します。`use`の場合はVAPID鍵を自動生成し、git管理外の`mise.local.toml`の`[env]`へ`VAPID_PUBLIC_KEY`、`VAPID_PRIVATE_KEY`、開発用`VAPID_SUBJECT=https://localhost`として保存します。

Web Pushは購読1件につき1件のActive Jobを必須とします。Web Push選択時はActive Job質問を省略し、未指定値を理由付きで`solid_queue`へ正規化します。CLIで`--web-push=use --active-job=skip`を明示した場合は拒否し、同期送信や別adapterへのフォールバックは追加しません。

## `active_job`

- CLI引数: `--active-job=solid_queue|skip`
- 質問文: ジョブ管理を使用しますか？
- 選択肢: `solid_queue`、`skip`
- 既定値: `skip`
- 表示条件: `web_push != use`
- 影響する処理: `solid_queue` gemとinstall generator、SQLite queue database、Active Job adapter、development用Puma plugin、production worker

`solid_queue`の場合、applicationのActive Job adapterを`solid_queue`に設定し、test環境だけenqueue assertionと外部worker非依存の決定的なテストのため`test` adapterへ明示的に上書きします。developmentには`storage/development_queue.sqlite3`を専用queue databaseとして定義し、`db/queue_schema.rb`を`db:prepare`で読み込んだうえでPuma pluginからSolid Queueを起動します。productionではPumaから起動しません。`deployment == dokploy`の場合は`Procfile.prod`のworkerプロセスで`bin/jobs --mode async`を実行し、`deployment == none`の場合はproductionでの起動方法を設定しません。

## `job_operations`

- CLI引数: `--job-operations=enable|disable`
- 質問文: 管理者向けジョブ運用画面を使用しますか？
- 選択肢: `enable`、`disable`
- 既定値: 適用可能な場合は`enable`
- 表示条件: `web_push == use`または`active_job == solid_queue`
- 影響する処理: Mission Control Jobs、`/admin/jobs`の管理画面、管理者用navigation、ジョブ運用文書

Mission Control JobsはSolid Queueのqueue、job、worker、定期task、失敗とretry状況を監視・操作するため、実効値が`active_job == solid_queue`の場合だけ利用できます。Solid Queueを使用しない場合は質問せず`disable`へ正規化し、確認画面へ理由を表示します。CLIで`--job-operations=enable`とSolid Queueを使用しない設定を同時に明示した場合は、`rails new`開始前に矛盾として拒否します。inline、async、別queue adapterへの切替は行いません。

`enable`ではMission Control Jobs 1.1.0を`/admin/jobs`だけへmountし、公式`base_controller_class` extension pointから既存の`Admin::BaseController`、管理者role、Action Policyへ接続します。Mission Control標準のHTTP Basic認証は無効化し、追加のusername/passwordは要求しません。host側のadmin navigationとdocument titleはja/enに対応し、engineの英語label、route、操作契約は維持したまま、host側のdaisyUI View overrideで表示します。Bulma stylesheetとBulma classは生成しません。

Solid Queue 1.6.0の公式install generatorは`config/recurring.yml`へ、完了ジョブを毎時12分に`SolidQueue::Job.clear_finished_in_batches`で整理するtaskを生成します。完了ジョブの保持期間は公式既定の1日です。失敗ジョブは`finished_at`を持つcleanup対象ではなく、管理者がretryまたはdiscardするまで保持されます。このcleanupはqueue database全体の運用要件なので、`job_operations=disable`でもSolid Queue標準生成物から削除しません。

## `maintenance_tasks`

- CLI引数: `--maintenance-tasks=enable|disable`
- 既定値: 適用可能な場合は`enable`
- 選択肢: `enable`、`disable`
- 表示条件: `web_push == use`または`active_job == solid_queue`
- 影響する処理: Shopify Maintenance Tasks、標準Run migration、`/admin/maintenance_tasks`の管理画面、管理者用navigation

Maintenance TasksはActive Jobを介して実行するため、実効値が`active_job == solid_queue`の場合だけ利用できます。Solid Queueを使用しない場合は質問せず`disable`へ正規化し、確認画面へ理由を表示します。CLIで`--maintenance-tasks=enable`とSolid Queueを使用しない設定を同時に明示した場合は、`rails new`開始前に矛盾として拒否します。同期実行やinline adapterへの切替は行いません。

`enable`では`maintenance_tasks` 2.17.0の公式install generatorを実行し、Gem標準のRun modelとmigrationでstatus、cursor、error、job ID、arguments、metadataを管理します。engineは`/admin/maintenance_tasks`だけへmountし、既存のadmin認証、Action Policy、admin layoutを再利用します。管理画面はBulmaを読み込まず、host側のdaisyUI View overrideを使用します。実taskやplaceholderは生成しません。

## `additional_login_methods`

- CLI引数: `--additional-login-methods=siwe`または`--additional-login-methods=`
- 質問文: 追加するログイン方法を選択してください。
- 選択肢: `siwe`の複数選択
- 既定値: 選択なし
- 表示条件: 常に表示する
- 影響する処理: Deviseの`:siweable` module、`siwe-rb`、SIWE credential・challenge・route・管理画面

Devise 5.0.4、`devise-i18n`、`webauthn ~> 3.4`によるPasskey登録・ログインはすべての構成で生成します。`User`は内部識別子`id`、ランダムで変更不可の`webauthn_id`、`remember_created_at`を持ち、`login_id`、`encrypted_password`、パスワード画面は生成しません。Passkeyはdiscoverable credential、`residentKey: required`、`userVerification: required`、`attestation: none`で登録し、ユーザーID入力なしでログインします。

`PasskeyCredential`はUserごとに複数登録でき、credential IDを全Userで一意にします。登録時のBackup Eligibilityは変更不可で、認証時にも不変性を検証します。Backup State、sign count、last usedは認証成功時だけ更新し、`BE=0/BS=1`はdatabase・model・認証境界で拒否します。全資格情報が`BS=0`のPasskey 1件だけならログイン後に紛失リスク警告を表示します。

`siwe`を選択した場合だけ`siwe-rb` 0.2.xとDeviseの`:siweable` moduleを追加します。SIWEは新規登録とログインを別purposeにし、ログインは既存identityだけを受け付けます。名前付きEOA walletをUserごとに複数登録でき、addressは全Userで一意かつ変更不可です。

WebAuthnとSIWEのchallengeはdatabaseへtoken digest、purpose、User、browser session、5分の期限、消費時刻、必要に応じて削除対象を保存します。発行・検証はPOST＋CSRF、`Cache-Control: no-store`、IP＋sessionごとのrate limitで保護します。Passkey・walletの解除は削除対象自身を候補から除外した別資格情報、アカウント削除は任意の現存資格情報による操作単位の再認証を要求します。最後の資格情報、別Userの対象、期限切れ・再利用challengeは拒否します。

CLIの配列optionはschema共通処理でカンマ区切りを宣言順へ正規化します。空値を選択なしとして受け入れ、未知値、重複値、空要素を生成開始前に拒否します。旧optionのaliasや互換処理は提供しません。

## `profile_features`

- CLI引数: `--profile-features=screen_name,display_name,avatar`
- 質問文: プロフィール機能を選択してください。
- 選択肢: `screen_name`、`display_name`、`avatar`の複数選択
- 既定値: 3機能すべて
- 表示条件: 常に表示する
- 影響する処理: Profile model・1対1 User association・プロフィール表示／編集画面・headerの認証後メニュー

対話UIは`Gum.choose(..., no_limit: true)`を使用し、3項目を選択済みとして表示します。何も選択しない回答は有効です。CLIではカンマ区切りで指定し、`--profile-features=`を何も選択しない回答として扱います。未知の値、重複値、空要素を含む値は生成開始前に拒否します。

1つ以上を選択した場合だけ、Userと1対1のProfile model、表示画面、編集画面、更新処理、account navigationの「プロフィール」を生成します。ProfileはUser作成時に同時作成し、User削除時に従属削除します。

`screen_name`を選択した場合はHaikunatorで小文字の英単語と数字をアンダースコアで連結した値をUser作成時に自動生成し、必須かつ一意にします。入力できる文字も小文字の英数字とアンダースコアだけに制限します。`display_name`を選択した場合もUser作成時にHaikunator由来の値を自動生成し、必須かつ一意な公開表示名として扱います。両方を選択した場合は、先に一意な`screen_name`を生成し、その値をCamelCaseへ変換した同一由来の値を`display_name`に設定します。databaseには各選択済みcolumnの`NOT NULL`制約とunique indexを作成し、modelでもpresenceとuniquenessを検証します。

`avatar`を選択した場合だけ`boring_avatars ~> 0.1.0`、Cropper.js 2.1.1、汎用`image_crop` Stimulus controller、Profileの`has_one_attached :avatar`を追加し、Action Textとともに常設済みのActive Storageを利用します。Cropper.jsとtransitive dependencyはImportmapの公式`pin` commandで`vendor/javascript`へ保存し、実行時CDNは使用しません。画像未設定時はUser IDの文字列表現をseedとして、`beam` variantとRapid Rails themeのbase-100、primary、base-200、secondary、base-300に対応するpalette（`#ffffff`、`#3ea8ff`、`#f1f5f9`、`#0f83fd`、`#d6e3ed`）からBoring Avatar SVGを生成します。seed専用columnは追加しません。設定済み画像はプロフィール編集画面の独立した確認付き操作で削除でき、削除後はBoring Avatarへ戻ります。

添付avatarは40×40の`header_avatar`と64×64の`profile_avatar`というnamed variantだけを使用し、いずれも中央基準の正方形cropとします。表示寸法とvariant名の対応は共通helperの定数を正本とし、未知の寸法や画像処理失敗を元画像表示で隠しません。HTMLにも幅と高さを出力します。

`image_crop` controllerはアスペクト比、初期coverage、出力幅・高さ、許可MIME type、入力上限、lossy品質をStimulus valuesで受け取ります。アスペクト比を省略すると自由cropとなり、出力幅・高さもそれぞれ省略可能です。指定された出力寸法はCropper.jsへ渡し、選択範囲の比率を保ったcanvasを生成します。不正または空の設定値は暗黙に補正せず、controller接続時に明示的に失敗させます。

avatarの選択元画像は静止画JPEG、PNG、WebPだけを許可し、5 MiB以下、幅・高さとも4096px以下に制限します。プロフィールViewは汎用controllerへアスペクト比1、初期coverage 0.8、出力幅・高さ512、lossy品質0.9を指定します。ブラウザ側では1:1を維持する可変crop枠で構図を決め、Crop確定時に元のMIME typeとfilenameを維持した512×512のFileへ変換します。PNGはlossless、JPEGとWebPはquality 0.9とし、確定済みFileを通常のprofile formが送信するまでuploadしません。再選択後のcancelでは直前に確定したFileとpreviewを復元し、変換失敗時に元画像送信へfallbackしません。

サーバー側はcrop済みuploadについても静止画JPEG、PNG、WebP、5 MiB以下、幅・高さ4096px以下、かつ正方形であることを検証します。空ファイル、申告MIMEと実形式の不一致、decode不能画像、GIF、APNG、animated WebP、長方形画像を拒否し、検証成功後だけActive Storageへ添付します。formの`accept`と説明文、I18n errorはこのpolicyと一致させます。Action Text添付にはavatar policyを適用しません。

認証後のheader menu triggerは、設定済み画像またはBoring Avatarとし、クリックとhoverの両方で展開します。プロフィール詳細も同じ共通helperを使用します。`avatar`を選択しない場合はHeroiconsの`bars-3`と`MENU` textをtriggerにします。展開内容は、選択済みなら`display_name`と`screen_name`、account navigationと同じ項目群、ログアウトの順です。

何も選択しなかった場合はProfile model、migration、controller、route、View、test fixtureを生成しません。header menuは`bars-3` + `MENU`を使い、account navigationからプロフィール項目を除外します。

## `api`

- CLI引数: `--api=enable|disable`
- 質問文: API機能を有効にしますか？
- 選択肢: `enable`、`disable`
- 既定値: `enable`
- 表示条件: 常に表示する
- 影響する処理: `/api` namespace、Bearer token認証基盤、`ApiCredential` modelとAPI/Web CRUD、マイページのAPIキー管理画面

`enable`では、`Api::ApiController`を`ActionController::API`基盤の共通controllerとして生成し、`Authorization: Bearer <api_key>.<api_secret>`を検証します。`api_secret`は生成時と再発行時に一度だけ返し、databaseにはSHA-256 digestだけを保存します。照合には定数時間比較を使い、認証済みcredentialが属するUserのデータだけを操作します。

`Api::ApiCredentialsController`は`/api/api_credentials`でCRUDと`revoke`を提供します。マイページ側の`ApiCredentialsController`も同じUser所有scopeでCRUDし、「APIキーの管理」から作成、表示、名称変更、削除、ApiSecretのrevoke（新しいsecretへの再発行）を行えます。API key自体はcredentialを識別する公開値として維持し、revokeではsecretだけを差し替えます。一覧画面と詳細画面ではAPI keyをreadonly inputとコピーボタンで表示し、ApiSecretも作成・再発行直後に限って同じコピーUIで一度だけ表示します。Bearer tokenは画面には表示しません。`disable`ではmodel、migration、controller、route、View、メニュー項目を生成しません。

## `solid_cache`

- CLI引数: `--solid-cache=use|skip`
- 質問文: Solid Cacheを使用しますか？
- 選択肢: `use`、`skip`
- 既定値: `use`
- 表示条件: 常に表示する
- 影響する処理: `solid_cache` gem、install generator、production cache database

## `action_cable`

- CLI引数: `--action-cable=solid_cable|skip`
- 質問文: Action Cableを使用しますか？
- 選択肢: `solid_cable`、`skip`
- 既定値: `skip`
- 表示条件: 常に表示する
- 影響する処理: RailsのAction Cable生成option、`solid_cable` gemとinstall generator、production cable databaseと`cable.yml`

`solid_cable`の場合、productionだけSolid Cable adapterを使用します。`skip`の場合は`rails new`へ`--skip-action-cable`を渡し、Action Cableに依存するTurbo Streamsのbroadcast機能が利用できないことを実行予定に表示します。

## `mail`

- CLI引数: `--mail=auto|use|skip`
- 質問文: メール機能を使用しますか？
- 選択肢: `auto`、`use`、`skip`
- 既定値: `auto`
- 表示条件: 常に表示する
- 影響する処理: Action MailerとAction Mailboxのgenerator option

`auto`は自動的にメールを必要とする機能がないため`skip`へ正規化します。Deviseだけを理由にメールを有効化しません。`skip`の場合は`rails new`へ`--skip-action-mailer --skip-action-mailbox`を渡します。確認画面には`auto`ではなく、正規化後の実効値と理由を表示します。

## `deployment`

- CLI引数: `--deployment=dokploy|none`
- 質問文: デプロイ方法を選択してください。
- 選択肢: `dokploy`、`none`
- 既定値: `dokploy`
- 表示条件: 常に表示する
- 影響する処理: Docker関連のgenerator option、production用Docker/Procfile/Litestream、Dokploy設定

`dokploy`ではRails標準のDocker/Kamalを使用しません。`rails new`へ`--skip-docker --skip-kamal`を渡し、Rails標準のThruster Gemと`bin/thrust`は生成します。Application Templateから`Dockerfile.prod`、`.dockerignore`、`bin/docker-entrypoint`、`Procfile.prod`、`litestream.yml`を生成し、`foreman`をproductionで利用できるGemとして追加してLitestreamをDocker imageへinstallします。

`none`でも`rails new`へ`--skip-docker --skip-kamal`を渡し、Thruster Gemと`bin/thrust`は生成しますが、production用Dockerfile、Procfile、Litestream設定、`foreman`、Dokploy固有設定を追加しません。

`dokploy`を選択した場合は`Procfile.prod`へ`bin/thrust bin/rails server`を定義し、Thrusterが既定のHTTP port 80で待ち受け、既定target port 3000のPumaを管理します。`active_job == solid_queue`の場合だけworkerプロセスも追加します。コンテナの既定commandがLitestream経由でForemanを起動し、Foremanが`Procfile.prod`のプロセスを管理します。

primary SQLite databaseとActive Storageのstorage SQLite databaseは常にLitestreamのreplication対象とし、queueとcableは対応する機能を選択した場合だけ追加します。`STORAGE_DATABASE_PATH`と`LITESTREAM_STORAGE_REPLICA_URL`を含む必要なdatabase path、replica URL、S3互換storageの認証情報が不足した場合は実行を失敗させます。

## テスト要件

- 各選択肢と既定値が正規化後の設定へ正しく反映されること。
- CLI引数で指定した項目を再質問せず、未指定の適用可能な項目だけを質問すること。
- `additional_login_methods`と`profile_features`をGumの複数選択で収集し、選択なしを有効な回答として扱うこと。
- schema上の全配列optionのカンマ区切り値を宣言順へ正規化し、未知値、重複値、空要素を拒否すること。
- `--profile-features`の空値でProfile関連生成物をすべて省略し、`--additional-login-methods`の空値でSIWE固有生成物をすべて省略すること。
- Active Storageと`active_storage_db`はAction Textとともに常設し、全環境でファイル本体を専用storage SQLite databaseへ保存すること。
- `--image-delivery`を不明なoptionとして拒否し、全Active Storage URLを`rails_storage_proxy`へ解決すること。
- 実画像variantがlibvipsで一度だけ生成され、proxy responseが`public`かつ`immutable`であること。
- `avatar`選択時だけBoring Avatars、Profile添付、User ID由来の既定アバター、header trigger、画像削除routeを生成すること。
- 設定済み画像がBoring Avatarより優先され、削除後は同じUser ID由来のBoring Avatarへ戻ること。
- すべての適用可能な項目をCLI引数で指定した場合、標準入力を読まずに実行すること。
- 表示条件が満たされない質問を行わないこと。
- すべての適用可能な質問を一度ずつ完了するまで最終確認へ進まないこと。
- 質問の依存関係に循環がある場合、ランチャーのbuildまたは起動時検証で拒否すること。
- 質問中と最終確認待ちでは、生成先、一時ファイル、Gemfile、外部commandへ副作用がないこと。
- 無効値や矛盾する組み合わせを変更開始前に拒否すること。
- 選択結果に対応するstepだけが実行計画へ追加されること。
- 最終確認で中止した場合、どの選択結果でもテンプレート固有の変更を開始しないこと。
- 最終確認に質問時の回答、正規化後の実効値、解決理由、全実行予定が表示されること。
- 承認後に質問が行われず、確定済み設定と実行計画が変化しないこと。
- `mail == auto`が追加ログイン方法にかかわらず`skip`へ正規化されること。
- PWAを使わない場合、Web Pushを質問せず`web-push` gemを追加しないこと。
- `pwa=skip + web_push=use`と`web_push=use + active_job=skip`の明示矛盾を変更開始前に拒否すること。
- Web Push使用時はActive Jobを質問せず、未指定値を理由付きでSolid Queueへ正規化すること。
- Solid Queue使用時だけMaintenance Tasksを質問し、適用可能な場合は`enable`を既定値とすること。
- Solid Queue使用時だけジョブ運用画面を質問し、適用可能な場合は`enable`を既定値とすること。
- Solid Queueを使わない場合はジョブ運用画面を`disable`へ正規化し、明示`enable`との矛盾を変更開始前に拒否すること。
- ジョブ運用画面を使わない場合、Mission Control JobsのGem、initializer、controller、helper、policy、route、daisyUI View override、navigation、locale、文書を生成しないこと。
- Solid Queueを使わない場合はMaintenance Tasksを`disable`へ正規化し、明示`enable`との矛盾を変更開始前に拒否すること。
- PWA使用時だけmanifest route、Service Worker route、manifest link、登録controllerを有効化すること。
- Web Pushの購読再割当て、VAPID検証、所有者再確認、失効削除、一時障害retry、恒久障害failureを外部Push serviceへ接続せず検証すること。
- Passkey-only構成とPasskey＋SIWE構成で購読APIと共通設定UIをDevise認証・CSRF保護し、ブラウザAPIを決定的にstubして購読、鍵変更、解除、拒否、非対応、テスト通知を検証すること。
- Solid Queueを使わない場合、queue database、Puma plugin、production workerを生成しないこと。
- Maintenance Tasksを使わない場合、Gem、migration、initializer、controller、route、navigationを生成しないこと。
- Action Cableを使わない場合、Solid Cableとcable databaseを生成しないこと。
- 全構成でRails標準のThruster Gemと`bin/thrust`を生成し、`--skip-thruster`を使用しないこと。
- `deployment == dokploy`で`Dockerfile.prod`、`Procfile.prod`、entrypoint、Litestream設定を生成し、Rails標準DockerとKamalは生成しないこと。
- `deployment == none`でDocker、Kamal、Procfile、Litestream、`foreman`を生成・追加しないこと。
- `deployment == dokploy`かつ`active_job == solid_queue`の場合だけ`Procfile.prod`へworkerを追加すること。
- `deployment == dokploy`でprimaryとActive Storageのstorageを常にreplicateし、queueとcableを選択に応じて追加すること。
