# 採用技術とセットアップ要件

この文書は、生成するRailsアプリケーションへ必ず導入する技術と、対話結果に応じて導入する技術を定義します。

## ランチャーUI

`bootstrap.rb`の対話UIには`marcoroth/gum-ruby`の`gum` 0.3.2を使用します。gemに同梱された現在のplatform向けGum実行可能ファイルを利用し、RailsアプリIDと表示用アプリ名の入力は`Gum.input`、個別オプションの選択は`Gum.choose`、実行計画の最終確認は`Gum.confirm`で行います。bootstrap自身によるgemの自動install、別versionへの暗黙の切り替え、標準入力を直接読む代替UIは行いません。

## Application IdentityとI18n

Rails内部識別子は`--app-id`から`rails new --name`へ渡し、ユーザー向け表示名は`--app-name`から生成アプリのApplication Identityへ保存します。両者を同じ設定値や暗黙の変換で兼用しません。

生成アプリはRails 8.1の`config_for`で`config/application_identity.yml`を読み、検証済みの`ApplicationIdentity`を`Rails.configuration.x.application_identity`へ設定します。developmentは`http://localhost:3000`、testは`http://www.example.com`をcanonical originとし、productionは`APPLICATION_ORIGIN`を必須とします。originの不足時にrequest hostへ切り替える処理は持ちません。同じoriginからroutesとAction Mailerの`default_url_options`、canonical URL、OGP URLを構築します。

I18nは`ja`と`en`だけをavailable localeとし、`--default-locale`の値を`config.i18n.default_locale`へ設定します。request境界では`I18n.with_locale`を使用し、locale fallbackを無効化します。Rails validationには`rails-i18n`、認証には常設の`devise-i18n`を使用し、アプリ固有のView、controller、JavaScript表示文面は生成するlocale fileのja/enペアを正本とします。

## 固定構成

| 分類 | 採用技術・Gem | 方針 |
| --- | --- | --- |
| データベース | SQLite（`sqlite3`） | 開発・テスト・productionで使用する |
| Webサーバー | Puma | RailsアプリケーションのWebプロセスとして使用する |
| Asset Pipeline | `propshaft` | Sprocketsへ切り替えない |
| JavaScript配布 | `importmap-rails` | Node.jsを前提とするJS bundlerを導入しない |
| Hotwire | `turbo-rails`、`stimulus-rails` | TurboとStimulusを使用する |
| CSS | `tailwindcss-rails`、`daisyui` | Rails統合版Tailwind CSS 4と最新のdaisyUI 5を使用する |
| テスト | Minitest | Rails標準のtest frameworkを維持する |
| 型検査 | `sorbet`、`sorbet-runtime`、`tapioca` | 漸進的型付けとGem／Rails DSL RBI生成に使用する |
| システムテスト | `capybara`、`capybara-playwright-driver` | SeleniumではなくPlaywright driverを使用する |
| fixture/factory | `factory_bot`、`factory_bot_rails` | テストデータ生成にFactory Botを使用する |
| ページネーション | `pagy` | ページネーションの標準実装とする |
| active link | `active_link_to` | 現在ページに応じたリンク表示に使用する |
| 認可 | `action_policy` | authorization policyの標準実装とする |
| Rich text・画像storage | Action Text、Active Storage、`active_storage_db`、`image_processing ~> 1.2`、`lexxy ~> 0.9.21` | 添付本体とvariantを専用SQLite databaseへ保存し、画像variantはlibvipsで処理する |
| 画像配信 | Active Storage proxy route、Thruster | 公開signed URLをHTTP cacheし、warm hitではPuma、Rails、SQLiteを迂回する |
| エラー監視 | `sentry-ruby`、`sentry-rails` | productionのエラー通知と追跡に使用する |
| Profile名生成 | `haikunator` | `screen_name`または`display_name`を選択した場合だけUser作成時の既定値生成に使用する |
| 既定アバター生成 | `boring_avatars ~> 0.1.0` | `avatar`を選択した場合だけUser IDから決定的なSVGを生成する |

Rails 8.1では、SQLite、Puma、Propshaft、Importmap、Turbo、Stimulus、Minitestが標準構成に含まれます。これらをGemfileへ重複追加せず、対象の`rails new`オプションと生成結果を検証します。Tailwind CSSは`--css=tailwind`を指定し、Railsが提供する`tailwindcss:install`処理を利用します。

daisyUIはTailwind CSS 4用pluginとして、Application Templateのpost-bundleフェーズで`npm install --save-dev daisyui@latest`により導入します。生成された`package.json`と`package-lock.json`を管理し、`app/assets/tailwind/application.css`へ組み込みthemeを無効化した`@plugin "daisyui"`と`@plugin "daisyui/theme"`によるcustom themeを登録します。JavaScript配布は引き続きImportmapを使用し、Node.jsはJavaScript bundlerではなくTailwind CSS plugin依存のinstallとasset buildにのみ使用します。`node_modules`はGitおよびDocker build contextへ含めません。

Dokploy用のproduction imageではbuild stageにNode.jsとnpmを導入し、lockfileに対して`npm ci`を実行してから`assets:precompile`を行います。生成済みCSSだけをfinal stageへ引き継ぎ、`node_modules`とNode.js runtimeはfinal imageへ含めません。

### daisyUIカスタムテーマ

組み込みthemeは`rapid-rails`という名前のlight themeとし、これだけを既定themeとして有効にします。daisyUI custom themeが要求する変数へ、`DESIGN.md`のZenn系デザインを次のように対応させます。

| theme token | 値 | 用途 |
| --- | --- | --- |
| `base-100` | `#ffffff` | page・card背景 |
| `base-200` | `#f1f5f9` | section・sub-layout背景 |
| `base-300` | `#d6e3ed` | border・separator |
| `base-content` | `rgba(0, 0, 0, 0.82)` | 本文 |
| `neutral` | `rgba(0, 0, 0, 0.55)` | 補足文・label |
| `primary` | `#3ea8ff` | 主要CTAとlink |
| `secondary` | `#0f83fd` | primaryのhover・press |
| `success` | `#10b981` | 成功通知 |
| `warning` | `#f59e0b` | 警告通知 |
| `error` | `#f43f5e` | error・危険操作 |

field radiusは`0.5rem`、box radiusは`0.75rem`、borderは`1px`、depthとnoiseは`0`に固定します。本文は16px・line-height 1.8、見出しはline-height 1.5、codeは14px・line-height 1.5とし、指定のsystem/Japanese font stackを使用します。本文へ`palt`を適用せず、`word-break: break-all`と`overflow-wrap: break-word`を設定します。補足文はopacityを重ねず`neutral`を直接使用して実効alphaを`0.55`に保ちます。入力欄にはdaisyUIの`--input-color` contractを利用する`input-rapid` utilityを併用し、通常時を`base-300`、focus時を`primary`へ切り替え、font sizeを16pxにします。buttonには`btn-rapid` utilityを併用して16px・weight 700とし、secondary buttonは公式の`btn-primary btn-outline`を組み合わせます。

`DESIGN.md`は任意のCSS Custom Propertiesへ依存しない方針ですが、daisyUI custom themeとcomponent自体が公式の`--color-*`、`--radius-*`、`--size-*`、`--input-color`等をcontractとします。daisyUIのtheme・component contractに必要な変数だけを例外として使用し、独自の追加変数やView内のraw palette colorは定義しません。

### 標準View構成

生成アプリケーションには、共通application layout、認証用sub-layout、メニュー付き画面用の`with_menu` partial layout、account用sub-layout、admin用sub-layout、header、flash、footer、公開home、認証必須の`/account`を必ず生成します。全Viewは`data-theme="rapid-rails"`配下でdaisyUI componentとsemantic colorを使用します。

Viewはcomponent-firstで構築します。daisyUIに意図が一致するcomponentやpart、modifierがある場合は、Tailwind CSS utilityだけで同等のUIを再実装しません。headerは`navbar`、guest向けdesktopの`button`群、guest向けmobileと認証後の`dropdown` + `menu dropdown-content`、footerは内側幅をheaderと共有する`footer`と`footer-title`、homeの導入部は`hero`、情報ブロックは`card`、FAQはnativeの`details`を使う`collapse`、account navigationは`menu-title`と`menu-active`を含む`menu`、formは`fieldset`、`fieldset-legend`、`input`、`file-input`、`checkbox`、`button`、補助導線は`divider`と`menu`、通知は`alert`を使用します。

Rails 8.1.3の`bin/rails app:templates:copy`で取得した標準ERB templateを基準に、`generate scaffold`用の6 Viewと`generate controller NAME ACTION`用のViewをdaisyUI向けに上書きします。生成アプリケーションの`lib/templates/erb/scaffold`と`lib/templates/erb/controller`へ変更したtemplateだけを配置し、mailerやRuby generator templateの未変更copyは配置しません。scaffoldの一覧は`table table-sm table-pin-rows`を`overflow-x-auto`で囲み、詳細・編集画面は`card`、属性表示は`list`、formは属性型に対応する`input`、`textarea`、`file-input`、`checkbox`を使用します。Rails標準のgenerator変数、添付ファイル、password digest、`dom_id`、route helperのcontractは維持します。

全生成Viewの主見出しは`content_for :page_title`へ文字列を1回だけ設定し、Viewまたは`with_menu` layoutの`h1`とdocument titleから再利用します。document titleと`og:title`は通常ページで「page title | application name」、`page_title`を持たない公開homeだけapplication nameとします。主見出し直前のeyebrowは置かず、カードや機能紹介など主見出しではないsection headingは維持します。

account navigationはdaisyUIの`menu with icons`として構築し、各linkの先頭へHeroiconsの24px outline SVGを`size-5`で配置します。マイページには`home`、Profile生成時のプロフィールには`user-circle`、アカウント設定には`cog-6-tooth`、Web Push使用時の通知には`bell`を使用し、SVGは装飾要素として`aria-hidden="true"`にします。headerの認証後dropdownは、admin controllerでは見出し「管理画面」と管理項目だけを表示し、それ以外ではaccount項目だけを表示します。`avatar`選択時はdaisyUI `avatar`をtriggerにし、それ以外はHeroicons `bars-3`と`MENU` textを使用します。サイト全体のheaderにhome導線があるため、account navigation内へ「ホームへ戻る」は重複配置しません。

component内部の高さ、padding、配置はdaisyUIの既定値を優先します。特に`menu`直下のitemへ`min-h-*`や`p-*`を追加せず、サイズ変更が必要な場合は`menu-sm`から`menu-xl`までの公式modifierを選びます。Tailwind CSS utilityはpage placement、responsive layout、または`DESIGN.md`で値が明示された見た目の調整だけに使用し、component既定値を上書きする場合は理由を設計文書とテストへ残します。

- `/`は追加ログイン方法にかかわらず公開する。
- `/account`は認証必須とし、account sub-layoutで表示する。
- `profile_features`が1つ以上の場合だけUserと1対1のProfile、表示／編集／更新画面を生成する。Active StorageはAction Textとともに常設し、`avatar`選択時だけBoring AvatarsとProfileの添付画像機能を追加する。
- 画像未設定時はUser IDの文字列表現から`beam` variantのBoring Avatarを生成し、themeのbase-100、primary、base-200、secondary、base-300に対応する5色を使う。seedはDBへ保存しない。設定済み画像を削除した場合は同じ既定アバターへ戻す。
- `screen_name`または`display_name`選択時だけ`haikunator`を導入し、User作成と同時に必須かつ一意な既定値を設定する。両方の選択時はHaikunatorで生成した`screen_name`をCamelCase化して`display_name`とする。
- API機能を有効にした場合は、account navigationへ「APIキーの管理」を追加し、credentialの一覧、作成、詳細、名称変更、削除、secret再発行をaccount sub-layoutで提供する。一覧は`table`、formは`fieldset`と`input`、secretの一度限りの表示は`alert`、操作は`button`を使用する。
- login、passwordだけを入力するaccount登録、登録直後のユーザーID提示はauthentication sub-layoutで表示し、認証後のaccount設定はaccount sub-layoutで表示する。password recoveryは生成しない。
- Deviseのsessionsとregistrationsのapplication Viewをgeneratorで展開し、loginではユーザーID＋password、account登録ではpassword＋password confirmation、登録完了とaccount設定では読み取り専用ユーザーIDを表示する。コピー操作はAPI optionに依存しない共通Stimulus controllerを使用する。
- SIWE選択時だけlogin画面へ明示的な署名buttonを追加する。account navigationへ独立項目は追加せず、「アカウント設定」内の`tabs-lift`で「基本設定」と「EVMウォレットログイン」を切り替える。wallet管理はresourcefulな一覧・新規登録・編集・解除画面へ分離し、解除画面だけでcurrent passwordを要求する。
- bodyのpage背景は`base-100`、main content sectionは`base-200`とし、cardは`base-100`へ戻して境界を明示する。
- headerとfooterは全幅のbackground・borderと、`max-w-6xl`の内側componentを分離する。メニュー付き画面はRailsの`render layout:`で`with_menu` partial layoutを適用し、accountとadminのsub-layoutが`content_for :with_menu_navigation`へ固有menuを1回だけ設定して本文をlayout blockとして渡す。`with_menu`は呼出元を判定せず、`max-w-6xl`、水平padding、`220px + minmax(0, 1fr)`のgrid、名前付きnavigation、`content_for(:page_title)`の主見出し、layout blockの本文を配置する。961px未満では1列へ切り替え、左ペインの`menu`を本文より先に表示する。
- account sub-layoutの左ペインにはユーザー向けmenuだけを表示し、管理項目を混在させない。admin sub-layoutの左ペインには見出し「管理画面」と、ユーザー管理、固定ページ管理、FAQ管理、外部リンク設定の管理menuだけを表示し、account項目を混在させない。現在のControllerに対応するlinkは`menu-active`と`aria-current="page"`で示す。
- 複数Viewで共通する階層メニューは個別Viewへ複製せず、その画面群の機能単位nested layoutで1回だけ定義する。`with_menu`が主見出しを描画してからnested layoutを本文blockとして受け取るため、表示順は主見出し、subnavigation、本文となる。
- tabpanelを伴うタブは`ApplicationHelper#with_tab`だけで生成する。helperは各tabのoptionalな`is_active` lambdaを優先し、未指定時は`request.path.start_with?(path)`で候補を判定する。複数候補では最長pathを選び、同長競合または候補なしは明示的に失敗させる。必要な場合だけoptionalな`size:`でdaisyUI公式の`tabs-xs`から`tabs-xl`を選ぶ。Railsの`capture`で取得した本文はactiveな`tab`の直後へ1件だけ`tab-content sticky [contain:inline-size] bg-base-100 border-base-300 p-3`として置く。stickyなtabpanelの上borderが共有境界へ重なってもactive tabの下へ線が出ないよう、active tabへ`z-10`を付ける。inline-size containmentによりtabpanel本文のmax-content幅をtablistの必要幅から除外する。`tabs tabs-lift min-w-max`を`overflow-x-auto`で囲み、狭幅でも折り返さず横スクロールできるようにする。inactive用の空tabpanelや個別Viewの幅補正は生成しない。各画面の最外周へ同じbase borderを持つcardは重ねない。tabpanelを伴わないtab形式selectorは対象外とする。
- `640px`以下をmobile、`960px`以下をtablet、`961px`以上をdesktop layoutとして扱う。desktopとmobileの両方で1columnへ縮退できることを必須とする。44pxのtouch targetを満たすためにcomponent itemへ一律の`min-h-*`を追加せず、必要な場合はdaisyUIの公式size modifierまたはtheme tokenでcomponent全体として調整する。

### Action Text、固定ページ、FAQ、footer設定

Action Text、Active Storage、Active Storage DB、Lexxyは選択式にせず、すべての生成アプリケーションへ導入します。Action Textの公式install generatorでActive Storageのmetadata／attachment migrationと添付表示partialを生成し、`active_storage_db`の公式migration taskでファイル本体用migrationを生成して`db/storage_migrate`へ分離します。Active Storage DB engineを`/active_storage_db`へmountし、development、test、productionのActive Storage serviceをすべて`:db`に設定します。Active Storageのblob metadataとattachmentはprimary database、ファイル本体は専用storage SQLite databaseへ保存し、Disk serviceへ暗黙に切り替えません。

Active Storageのvariant processorは全環境で`:vips`、variant trackingは有効、route resolverは`:rails_storage_proxy`へ固定します。Rails標準生成物の`image_processing ~> 1.2`を利用し、Dokploy用runtime imageには`libvips`を含めます。Profile avatarは40×40の`header_avatar`と64×64の`profile_avatar`だけをnamed variantとして定義し、任意の変換hashをViewへ記述しません。attachmentとblob metadataはprimary SQLite、元画像と処理済みvariant本体はActive Storage DBの専用storage SQLiteをsource of truthとします。

生成アプリをDocker外で開発・testするhostにもlibvips runtimeが必要です。macOSでは`brew install vips`など、対象OSのpackage managerでlibvipsを明示的に導入し、`Vips::Image`が実画像をdecodeできることをtestで確認します。

Active Storageのblobとrepresentationは公式proxy controllerから配信します。初回requestはThruster、Puma、Rails、Active Storage DBを通り、Railsが`public`かつ`immutable`なresponseを返します。同じsigned URLがThrusterのmemory cacheに残っている間はThrusterが直接返却します。生成済みvariantはlibvips処理を省略しますが、Thruster cacheがcoldならRailsとSQLiteの読出しは発生します。Action Textのoriginal、download、削除とavatar policyは分離し、global proxy resolverでも各契約を検証します。

Thrusterのcache既定値は全体64 MiB、1 responseあたり1 MiBです。process再起動、eviction、上限超過、Range requestではcacheを利用できません。このtemplateはCDN、永続cache、独自cache middlewareを追加しません。Active Storageのproxy URLは恒久的で、URLを知る利用者へ公開されるため、認証必須の添付は対象外です。

Importmapへ`lexxy`と`@rails/activestorage`を登録します。管理formはRails標準の`rich_text_area`を使用し、Rails 8.1向けLexxy overrideでeditorを置き換えます。公開本文はAction Text content layoutを`lexxy-content`で包み、Lexxy stylesheetと同じ表示規則を適用します。

公開固定ページは`/about`、`/corp`、`/manual`、`/terms`、`/privacy`、`/transaction-law`とし、routeごとの固定slugを共通の`PagesController#show`へ渡します。`Page`のslugはこの6値へ限定し、titleとともにseedで冪等作成します。管理者は本文だけを更新でき、固定ページの作成、削除、slug、titleの変更は提供しません。存在しない固定recordや未知slugを別ページへ戻すfallbackは設けません。

`Faq`は質問、表示順、公開状態、Action Text回答を持ちます。新規recordは非公開とし、公開画面`/faq`は公開済みrecordだけを表示順とIDの昇順で表示します。管理画面はCRUD、公開切替、表示順変更を提供します。

footerはロゴやbrand用asideを持たず、About、Guides、Links、Legalの4列を`footer`、`footer-title`、`link link-hover`で構成します。内部linkは固定routeを使用します。`FooterSetting`は固定keyのsingletonとしてseedし、XとGitHubの任意HTTPS URLを管理します。URLはhostを必須とし、userinfoとHTTPを拒否します。各linkは未設定なら非表示とし、両方未設定ならLinks列も表示しません。

### API認証とApiCredential

API機能を有効にした場合だけ、`/api` namespaceと`ApiCredential`を生成します。API requestは`Authorization: Bearer <api_key>.<api_secret>`で認証し、共通の`Api::ApiController`がcredentialと所有Userを確定します。認証失敗はHTTP 401、所有scope外のresourceはHTTP 404、validation失敗はHTTP 422のJSON responseとします。

`api_key`と`api_secret`は暗号学的乱数から個別に生成します。`api_key`は一意な検索キーとして保存し、`api_secret`は平文保存せずSHA-256 digestだけを保存します。secret比較には`ActiveSupport::SecurityUtils.secure_compare`を使用します。平文secretはcredential作成時とrevokeによる再発行時だけWeb画面またはJSON responseへ含め、後から再表示しません。revokeはcredentialや`api_key`を作り直さず、secret digestだけを原子的に更新します。

`User`は`ApiCredential`を複数所有し、User削除時に従属credentialも削除します。WebとAPIのCRUDはいずれも認証済みUserのassociationからresourceを検索し、別Userのcredentialを参照・変更できない構造にします。

Rails標準のシステムテスト構成にはCapybaraとSelenium WebDriverが含まれます。本構成ではCapybaraを維持し、Selenium WebDriverを`capybara-playwright-driver`へ置き換えます。Minitestプロジェクトなので、文書とコードでは「system spec」ではなくRailsの用語に合わせて「システムテスト」と呼びます。

## application gem

次のGemは条件にかかわらず導入します。

```text
pagy
active_link_to
action_policy
sentry-ruby
sentry-rails
lexxy
```

SentryのDSNやenvironmentなど、秘密情報と環境依存値はリポジトリへ埋め込みません。設定方法は実装フェーズで別途定義します。

`haikunator`は`screen_name`または`display_name`が選択された場合だけapplication Gemとして追加します。`screen_name`は`Haikunator.haikunate(9999, "_")`の候補から既存値と衝突しない値を採用します。`display_name`だけを選択した場合は`Haikunator.haikunate`の候補から既存値と衝突しない値を採用し、両方を選択した場合は一意な`screen_name`候補のCamelCaseも未使用であることを確認して同時に設定します。model validationに加えてdatabaseの`NOT NULL`制約とunique indexで不変条件を保証します。

`boring_avatars`は`avatar`選択時だけRails bindingを明示的に読み込みます。共通View helperがActive Storage添付を優先し、未添付時だけ`User#id.to_s`をseedとしてSVGを生成します。SVG内部IDはgemの衝突回避へ委ね、avatar seed用の永続化項目は追加しません。theme色はserver-side generatorが要求する16進色の定数として一元化し、CSS themeとの一致を契約テストで保証します。

### PWAとWeb Push

`pwa=use`ではRails 8.1標準のPWA controllerを利用し、`/manifest.json`と`/service-worker`を明示的にrouteへ接続します。manifestはApplication Identityの表示用アプリ名と既定locale、`/icon.png`、scopeとstart URL `/`、`standalone`表示、theme色`#3ea8ff`を持ちます。Service Workerの`push` handlerは`{ title, options }`を表示し、`notificationclick` handlerはpayloadの`options.data.path`を同一origin内へ制限した上で、既存windowのfocus・navigateまたは新規windowのopenを行います。

`web_push=use`では`web-push ~> 3.1`とSolid Queueを導入します。`PushSubscription`はUser、安定したbrowser ID、endpoint、`p256dh`、`auth`を保持し、browser IDとendpointをそれぞれ一意にします。登録時は両キーの既存recordをlockし、同一ブラウザの別accountログインや同一endpointの再登録を現在のUserへ移します。User削除時はassociationとdatabase外部キーの両方で購読を削除します。

VAPID設定は`VapidConfiguration`だけが`VAPID_PUBLIC_KEY`、`VAPID_PRIVATE_KEY`、`VAPID_SUBJECT`を読み、欠落、空値、不正なsubjectを明示的に失敗させます。開発用の生成鍵はgit管理外の`mise.local.toml`へ保存します。本番では3変数すべてが必須です。鍵を変更した場合、Stimulus controllerがapplication server keyの差異を検出して旧購読を解除し、現在の鍵で再購読します。旧鍵との二重運用は行いません。

アプリケーションからの送信入口は次の1つです。

```ruby
PushNotifier.deliver_later(
  user:,
  title:,
  body:,
  path:,
  tag: nil,
  icon: "/icon.png",
  ttl: 86_400
)
```

`path`は`/`から始まる同一origin内pathだけを受け付けます。各購読へ個別の`PushNotificationJob`をenqueueし、job実行時にもenqueue時のUser IDと現在の所有者を照合します。Web Push接続・読取・SSL timeoutは5秒です。失効・不正購読は削除し、rate limit、Push service、一時的network errorだけを最大5回再試行します。認証失敗、payload過大、VAPID設定不備は再試行せず失敗として表面化させます。

認証済みHTTP APIは次のinterfaceを提供します。全endpointを通常の認証とCSRFで保護し、購読secretはresponseやlogへ返しません。

| Method・path | Response・制約 |
| --- | --- |
| `GET /push_subscription/vapid_public_key` | `200 { public_key }`。設定不足は`503` |
| `POST /push_subscription` | browser ID、endpoint、`p256dh`、`auth`を登録・再割当てして`204` |
| `DELETE /push_subscription` | 現在のUser範囲でbrowser IDを冪等削除して`204` |
| `POST /push_subscription/test` | 現在のUserとbrowser IDに一致する購読へ固定通知をenqueueして`202`。未登録は`404`、設定不足は`503`、5回/分超過は`429` |

追加ログイン方法にかかわらず共通のDevise認証必須`/notification`ページを生成し、account navigationの独立項目「通知」から開きます。アカウント設定画面へWeb Push UIは埋め込みません。通知ページはdaisyUIの`card`、`toggle`、`btn`、`alert`とHeroiconsのbellを表示します。通知許可はtoggleをONにしたユーザー操作内だけで要求し、unsupported、default、granted、denied、通信中、失敗を画面へ反映します。

### Roleと認可

生成アプリケーションには固定roleを複数付与できる`UserRole`とAction Policyのpolicy基盤を常に生成します。初期roleは`admin`だけとし、一般Userはroleを持ちません。`UserRole`は内部識別子である`user_id`と文字列`role`を持ち、組み合わせの一意制約、外部キー、`NOT NULL`、許可roleのdatabase check constraintで不変条件を保証します。role定義はコードとmigrationで管理し、管理画面からrole種別そのものを追加・編集しません。

`User`は`has_role?`、`grant_role!`、`revoke_role!`を公開し、role付与を冪等にします。一般の登録・アカウント更新parameterへroleを含めず、role変更はAction Policyで保護された管理画面に限定します。複数roleの権限は許可を加算し、role階層と明示denyは持ちません。

管理画面は`/admin/users`に数値IDと、Profile有効時だけProfileの表示名をページング表示し、`admin`の付与と解除を提供します。`login_id`やwallet addressは表示しません。自分自身の`admin`解除と最後の`admin`解除・削除を拒否します。最初のadminは`users.id`を引数に取る`roles:grant_admin[user_id]` taskで既存Userへ付与し、local seedは`ADMIN_USER_ID`を使用します。

## テスト用Gem

```text
capybara
capybara-playwright-driver
factory_bot
factory_bot_rails
```

Playwright driverはChromium・headlessへ固定し、`playwright-ruby-client`が公開する互換CLI versionを`package.json`へ導入します。実行時は生成アプリケーションの`node_modules/.bin/playwright`を明示し、`playwright install chromium`でbrowser binaryを準備します。必要な実行ファイルがない場合にSeleniumへ戻すフォールバックは設けません。

UIエビデンスはCapybaraのroute遷移・入力・表示確認と、Playwright native pageのfull-page screenshotを組み合わせます。password基底の共通画面、SIWE固有差分、画像配信差分を重複しないscenario setとして1400×900と390×844で撮影します。共通画面は実際のDevise login form、SIWE差分はdatabase challengeと署名検証で同じUserへsessionを作成し、テスト専用認証routeは生成しません。

## 型検査・Schema annotation・Linter・Formatter・開発支援

development groupへ次を追加します。`annotaterb`はRails generatorから読み込むため通常どおり追加し、それ以外は`require: false`とします。

```text
annotaterb
sorbet
ruby-lsp
ruby-lsp-rails
rubocop-rails
rubocop-thread_safety
momocop
```

`sorbet-runtime`はruntimeで型注釈を利用できるよう全環境のapplication Gem、`tapioca`はRBI生成と検証のためdevelopment/test Gemとして追加します。テンプレートではversionを固定せず、生成アプリケーションの`Gemfile.lock`で解決versionを固定します。

[Sorbetの公式導入手順](https://sorbet.org/docs/adopting)に従って`bundle exec tapioca init`を実行し、`sorbet/config`、Tapioca設定、`bin/tapioca`、Gem RBI、annotation RBIを生成します。Action Policyのtest helperは`sorbet/tapioca/require.rb`へ明示します。Railsでmailをskipした構成でもTapioca CentralのAction Mailer annotationとGem RBIが食い違わないよう、Action MailerとMailも同じファイルから明示的に読み込み、3 GemのRBIを再生成します。test databaseを準備して`RAILS_ENV=test bin/tapioca dsl --environment=test`を全体へ実行し、Active Recordのschema・association・enum・scope・attachment、Active Jobのenqueue API、Action Mailerとroute helperなど、対応済みRails DSLのRBIを同じtest環境で確定します。必要なrequireとshimを生成した後は初期`todo.rbi`を削除し、未解決定数も`bundle exec srb tc`の通常エラーとして扱います。

Ruby 4.0で読み込まれる`net-imap` 0.6系の実装とSorbet payloadの間には、`Net::IMAP::Literal`と`Net::IMAP::QuotedString`の継承定義差があります。Tapiocaが生成するGem RBIを除外せず、Sorbetが案内する`--suppress-payload-superclass-redefinition-for`をこの2クラスだけに設定してpayload側との既知の衝突を解消します。

model、policy、service、job、mailer、validator、application-owned `lib`は生成時に`# typed: true`以上を先頭へ付与します。`ApplicationIdentity`、`ImageDeliveryConfiguration`、`AdminRoleGrant`、avatar upload／image policy、Web Push payload／notifier／VAPID設定は`# typed: strict`とし、private method、定数、instance variableも明示します。Web Push jobの引数はActive Jobが直列化できるprimitiveに限定し、job内で`PushNotificationPayload`へ構造化します。avatar uploadはRails／Rackの動的upload objectを`AvatarUpload`へ一度だけ検証変換します。Action View helperではtab入力を`T::Struct`、application route helper moduleをアプリ固有の`ApplicationRoutes`型、capture blockを`String`、Maintenance Tasksのbuilderを`ActionView::Helpers::FormBuilder`として表現し、application code内へ`T.untyped`を持ち込みません。route method本体はTapiocaが生成する`GeneratedUrlHelpersModule`と`GeneratedPathHelpersModule`を使い、runtime moduleへ付けた`ApplicationRoutes` markerとの接続だけを`framework_bindings.rbi`で表現します。Action Policyはgem側の`method_added` hookがSorbet runtime hookへ委譲しないため、policy predicateだけSorbet公式の`T::Sig::WithoutRuntime.sig`を使用します。`typed: ignore`による除外は行いません。

`sorbet/rbi/dsl`、`sorbet/rbi/gems`、`sorbet/rbi/annotations`はTapioca専有の生成物として手動編集しません。アプリがRubyで定義するmethodは元の`.rb`へinline signatureを書きます。手書きRBIは、Devise、Action Policy、Action View、route helper、fixture DSLなどのruntime wiringを表す`sorbet/rbi/shims/framework_bindings.rbi`、Boring AvatarsのGem RBIがRails binding内で参照する型aliasを補う`sorbet/rbi/shims/boring_avatars.rbi`、FFIまたはHTTPXのGem RBIが参照するRuby同梱Bundlerのfork hookを表す`sorbet/rbi/shims/bundler_connection_pool.rbi`に分離します。Bundler shimは認証optionに依存せず常に生成します。同じ定義が生成RBIへ追加された場合は`bin/tapioca check-shims`が重複として検出します。反復的な独自macroが複数classへmethodを生成するようになった場合だけcustom DSL compilerへ昇格します。

生成時に`# typed: true`以上を付ける対象はcontroller、concern、helper、model、policy、service、job、mailer、validator、application-owned `lib`、config、test、`db/seeds.rb`です。configではPuma、Importmap、Rails CI、Maintenance Tasksが`instance_eval`するreceiverをRuby本体の`T.bind`で明示し、RailsがApplication subclassへ動的に委譲する`config_for`だけを`framework_bindings.rbi`で表現します。migration、schemaはRails DSLと実行順依存が強いため`typed: false`に留めます。`.rake`内にapplication logicを置かず、`roles:grant_admin`は`typed: strict`な`AdminRoleGrant`を呼び出します。

生成時と通常のRails testで、`bin/tapioca gems --verify`、`RAILS_ENV=test bin/tapioca dsl --verify --environment=test`、`bin/tapioca check-shims`、`bundle exec srb tc`を実行します。`dsl --verify`はRails DSL生成物の鮮度、`check-shims`は手書き定義の重複、`srb tc`はRuby本体・inline signature・全RBIを合わせた整合性をそれぞれ保証します。Gem更新時は`bin/tapioca gems`、model、migration、routeなどRails DSL変更時はtest database準備後に`RAILS_ENV=test bin/tapioca dsl --environment=test`を実行し、更新されたRBIをcommitします。検証失敗時に古いRBIや型エラーを許容するfallbackは設けません。

`annotaterb`は公式の`annotate_rb:install` generatorで`.annotaterb.yml`と`lib/tasks/annotate_rb.rake`を生成します。設定は公式既定を使用し、modelに加えて対応するfixture、test、factory、serializerもschema annotationの対象とします。routes annotationは既定どおり無効とします。

すべてのmigrationを適用した後に`bin/annotaterb`を生成して`bin/annotaterb models`を実行し、生成直後のannotationを確定します。以後はdevelopment環境の`bin/rails db:migrate`など、公式hook対象のdatabase task後に自動更新します。通常のRails testには`RAILS_ENV=test bin/annotaterb models --frozen`を実行する検査を含め、annotationの変更が必要な場合はファイルを書き換えずに失敗させます。修正時は`bin/annotaterb models`を実行し、更新されたannotationをcommitします。

Rails標準の`rubocop-rails-omakase`は使用しません。生成後に`bundle remove`するのではなく、`rails new`へ`--skip-rubocop`を渡して最初から生成対象外とし、上記GemをApplication Templateの`gem` APIでbundle install前に宣言します。

`.rubocop.yml`のベースには、次のcommitへ固定されたGistを使用します。

```text
https://gist.githubusercontent.com/supermomonga/3ffe073e1c11cd9025d35d507038b9e2/raw/38a485963395626171243dce796e6dc541d61450/.rubocop.yml
```

外部コマンドの`curl`ではなく、Rails/Thorの`get` actionで取得します。取得失敗時に別URLや内蔵設定へ切り替えません。bundle installと設定完了後に`bin/rubocop -a`を実行し、終了状態を検証します。

### 現在のGistとの差分

固定されたGistは`AllCops.TargetRubyVersion: 3.4`ですが、本プロジェクトの対象はRuby 4.0.xです。また、現在の`rubocop-rails`と`rubocop-thread_safety`はRuboCopの`plugins`設定を案内し、`momocop`は`require`設定を案内しています。

取得後にYAMLとして構造化編集し、`AllCops.TargetRubyVersion`を`4.0`へ設定します。`rubocop-rails`と`rubocop-thread_safety`は`plugins`、`momocop`は`require`で読み込みます。

## Solid Queue

ジョブ管理を使用する場合だけ、現在解決される`solid_queue` 1.6.0を導入し、Active Job adapterを`solid_queue`に設定します。SQLiteではprimary databaseとqueue databaseを分け、developmentでは`storage/development_queue.sqlite3`へ接続して`solid_queue:install`が生成する`db/queue_schema.rb`と`db/queue_migrate`を使用します。生成中の`db:prepare`がこのqueue databaseも準備するため、Puma pluginの初回起動時からSolid Queueのtableが存在します。test環境だけはActive Storageを含むenqueue処理とjob assertionを外部worker・queue DBから分離するため、Rails標準の`test` adapterへ明示的に上書きします。

developmentではPumaからSolid Queueを起動します。

```ruby
plugin :solid_queue if ENV.fetch("RAILS_ENV", "development") == "development"
```

productionではPuma pluginを有効化せず、`bin/jobs`をworkerプロセスとして起動します。`deployment == dokploy`の場合だけ`Procfile.prod`へworkerを定義し、Webプロセスと同じコンテナ内でForemanから起動します。`deployment == none`でも`bin/jobs`自体は生成しますが、起動方法をこのテンプレートでは設定しません。

`solid_queue:install`が生成する`config/recurring.yml`の標準cleanupを維持します。`preserve_finished_jobs`は既定の`true`、`clear_finished_jobs_after`は既定の1日とし、毎時12分に`SolidQueue::Job.clear_finished_in_batches(sleep_between_batches: 0.3)`を実行します。cleanupは`finished_at`が保持期間より古い完了ジョブだけを対象とします。失敗ジョブは`solid_queue_failed_executions`に残り、管理者または運用者がretryかdiscardを行うまで削除しません。既存の`bin/jobs --mode async` supervisorがworker、dispatcher、schedulerを起動するため、cleanup専用processは追加しません。

## Mission Control Jobs

`job_operations=enable`かつ`active_job=solid_queue`の場合だけ、Mission Control Jobs 1.1.0を導入します。engineは`/admin/jobs`だけへmountし、root直下の`/jobs`や別pathへ公開しません。queue一覧、状態別job、worker、定期task、失敗内容、単体・一括retry/discardなど、Solid Queue adapterが提供する操作を使用します。

`MissionControl::Jobs.base_controller_class`には`Admin::JobOperationsController`を設定します。このcontrollerは既存`Admin::BaseController`を継承し、全engine actionを`JobOperationPolicy#manage?`で認可します。追加ログイン方法にかかわらずDeviseの`current_user`を既存Action Policy contextへ渡し、controller内でroleを直接判定しません。Mission Control標準のHTTP Basic認証は明示的に無効化し、別系統の認証は追加しません。

Mission Controlの公式ViewはBulma classを出力するため、Rails 8.1 Enginesの公式View lookup順序を利用し、Mission Control Jobs 1.1.0向けのhost Viewでlayout、application/server選択、section tab、flash、queue、状態別job、filter、worker、定期task、詳細、paginationをshadowします。Bulma stylesheetや専用CSSは生成せず、既存Tailwind CSS 4／daisyUI 5の`tabs`、`tab-content`、`card`、`table`、`badge`、`btn`、`fieldset`、`alert`、`collapse`、`mockup-code`、`join`へ統一します。engineのroute、controller、adapter、英語label、retry/discard/pause/resume/run操作は変更しません。専用layoutはQueues、Failed jobs、Workersなどのsection tabを`with_tab(size: :xs)`へ渡し、desktopのsection tabを1段へ収め、狭幅ではhelperのscroll container内で横スクロールさせます。`current_section`を参照するlambdaでactiveを判定してengine本文blockを直後のtabpanelへ渡します。各engine Viewは実際の画面名を`page_title`へ設定します。application/server選択はtabpanelを伴わないselectorなのでhelper対象外とし、tab content本文内に残します。通常画面ではhost Importmap、engine画面ではMission Control Importmapだけを出力し、専用layoutから既存admin layoutへnested renderします。admin navigationは生成アプリの既定localeに従い、document titleはengineのpage titleとapplication nameを組み合わせます。

Mission Control JobsとMaintenance Tasksは役割を分けます。Mission Control Jobsはqueueとjobの監視・retry/discard、Maintenance Tasksは運用taskの開始・進捗管理を担当し、`/admin/jobs`と`/admin/maintenance_tasks`のroute、policy、navigationを独立させます。

## Maintenance Tasks

`maintenance_tasks=enable`かつ`active_job=solid_queue`の場合だけ、Shopify `maintenance_tasks` 2.17.0を導入します。公式`maintenance_tasks:install` generatorが提供するmigrationをそのまま使用し、`maintenance_tasks_runs`で実行履歴、status、cursor、arguments、metadata、job ID、error class/message/backtraceを管理します。同じ情報を保持する独自modelやaudit tableは追加しません。

engineは`/admin/maintenance_tasks`へだけmountし、`Admin::MaintenanceTasksController`を`MaintenanceTasks.parent_controller`へ設定します。parent controllerは既存`Admin::BaseController`を継承し、全engine actionを`MaintenanceTaskPolicy#manage?`で認可します。metadataには`triggered_by_user_id`として`users.id`を保存し、追加ログイン方法にかかわらずDeviseの`current_user`を利用します。

engineのroute、controller、helper API、Run操作は2.17.0公式実装を維持し、専用layoutから既存admin layoutへnested renderします。Bulma stylesheetは読み込まず、Bulma classを出力するtask、run、errorのViewと表示helperをhost側でshadowして、既存Tailwind CSS 4／daisyUI 5のcard、badge、collapse、form、alert componentへ統一します。3秒ごとの`data-refresh`更新はhostのStimulus controllerで行い、外部stylesheet用CSP例外やinline scriptは追加しません。

Maintenance Taskは既存Solid Queue workerで実行します。Dokployでは既存`worker: bin/jobs --mode async`を共有し、専用workerを追加しません。`deployment=none`ではproduction worker processを生成せず、利用者がSolid Queue workerの起動と監視を別途構成します。

## Action CableとSolid Cable

Action Cableを使用する場合だけ`solid_cable`を導入し、production adapterをSolid Cableにします。

```yaml
production:
  adapter: solid_cable
  connects_to:
    database:
      writing: cable
  polling_interval: 0.1.seconds
  message_retention: 1.day
```

productionの`config/database.yml`には、常設のstorage databaseに加え、Action Cableを使用する場合だけprimaryとは別のSQLite cable databaseと`db/cable_migrate`を定義します。Action Cableを使わない構成では、Turbo DriveとTurbo Framesは利用できますが、Action Cableに依存するTurbo Streamsのbroadcast機能は利用できません。

## デプロイ方法

デプロイは固定構成ではなく、`dokploy`または`none`から選択します。既定値は`dokploy`です。

### `dokploy`

Rails標準のDocker/Kamal構成は使用せず、`rails new`へ`--skip-docker --skip-kamal`を渡します。Thruster Gemと`bin/thrust`はRails標準generatorから取得し、Application Templateが次のproduction専用ファイルを生成します。

```text
Dockerfile.prod
.dockerignore
bin/docker-entrypoint
Procfile.prod
litestream.yml
```

これらは本プロジェクトが管理するsource templateからRails/Thorの`template` actionで生成します。Rails標準Dockerfileを生成してから文字列置換する方式は採用しません。

Dokployではbuild typeをDockerfile、Dockerfile pathを`Dockerfile.prod`に設定します。コンテナの既定commandがLitestreamとForemanを起動するため、Dokploy側でweb/worker commandを個別に上書きしません。

#### Docker image

`Dockerfile.prod`は、公式Docker Hubに存在する対象範囲内の固定tag `ruby:4.0.0-slim`を使うmulti-stage buildとします。開発環境は`mise.toml`でRuby 4.0.6へ固定します。

- base stageでproduction用Bundler環境とLitestreamを用意する。
- build stageでGemをinstallし、build専用の`APPLICATION_ORIGIN=https://build.example.com`と`SECRET_KEY_BASE_DUMMY=1`でassetsをprecompileする。
- final stageには実行時Gem、SQLite、libvips、jemalloc、Litestream、アプリケーションだけを含める。
- `/data`をvolumeとして宣言し、SQLite databaseをimage layerやephemeral filesystemへ保存しない。
- Thrusterの既定HTTP port 80を公開し、内側のPumaは既定target port 3000で待ち受ける。
- YJITとjemallocを有効化する。
- entrypointを`bin/docker-entrypoint`へ固定する。
- 既定commandでLitestreamのreplicationを開始し、その`-exec`から`bundle exec foreman start --procfile=Procfile.prod`を実行する。

Litestreamは`0.5.14`へ固定し、linux/amd64とlinux/arm64のrelease assetをDockerのtarget architectureに応じて選択します。releaseの`checksums.txt`でdownloadしたassetを検証してからinstallし、検証失敗時に別versionや未検証binaryへ切り替えません。

#### production process

`foreman` gemは`deployment == dokploy`の場合だけ、productionで実行できるgroupへ`require: false`で追加します。`Procfile.prod`には必ずWebプロセスを定義します。

```procfile
web: bin/thrust bin/rails server
```

`active_job == solid_queue`の場合だけworkerを追加します。

```procfile
worker: bin/jobs --mode async
```

Pumaは`RAILS_MAX_THREADS`を既定5、`WEB_CONCURRENCY`を既定2として設定します。productionではSolid Queue Puma pluginを有効化しません。

#### SQLite database

productionのSQLite databaseは、次の環境変数で`/data`配下へ配置します。

| database | 環境変数 | 既定の配置例 | 条件 |
| --- | --- | --- | --- |
| primary | `DATABASE_PATH` | `/data/production.sqlite3` | 常に必要 |
| storage | `STORAGE_DATABASE_PATH` | `/data/production_storage.sqlite3` | 常に必要 |
| queue | `QUEUE_DATABASE_PATH` | `/data/production_queue.sqlite3` | Solid Queue使用時 |
| cache | `CACHE_DATABASE_PATH` | `/data/production_cache.sqlite3` | Solid Cache使用時 |
| cable | `CABLE_DATABASE_PATH` | `/data/production_cable.sqlite3` | Action Cable使用時 |

SQLite共通設定は`transaction_mode: immediate`、`timeout: 20000`とし、connection poolは`DATABASE_POOL_SIZE`、未指定時は`RAILS_MAX_THREADS`を使用します。storageには`db/storage_migrate`、queueには`db/queue_migrate`、cableには`db/cable_migrate`を`migrations_paths`として設定します。`deployment == none`でも複数database構成を維持し、productionのprimaryを`storage/production.sqlite3`、storageを`storage/production_storage.sqlite3`へ配置します。

`bin/docker-entrypoint`は必要なdirectoryを作成した後、`bundle exec rails db:prepare`を一度実行します。Rails 8.1の`db:prepare`は現在のenvironmentに定義された全databaseを初期化・migrateするため、tableの有無を独自に調べるrunnerやdatabase別の非公開処理は追加しません。失敗時はコンテナを起動せず終了します。

#### Litestream

Litestreamはproduction SQLite databaseをS3互換storageへreplicateします。`litestream.yml`には選択済みdatabaseだけを含めます。

- primaryは常にreplication対象とする。
- Active Storageのstorageは常にreplication対象とする。
- Solid Queue使用時だけqueueを追加する。
- Action Cable使用時だけcableを追加する。

各databaseは別のreplica URLを使い、認証情報をファイルへ埋め込みません。

| 用途 | 環境変数 |
| --- | --- |
| primary replica | `LITESTREAM_REPLICA_URL` |
| storage replica | `LITESTREAM_STORAGE_REPLICA_URL` |
| queue replica | `LITESTREAM_QUEUE_REPLICA_URL` |
| cable replica | `LITESTREAM_CABLE_REPLICA_URL` |
| access key | `LITESTREAM_ACCESS_KEY_ID` |
| secret key | `LITESTREAM_SECRET_ACCESS_KEY` |

Litestreamの設定または認証情報が不足した場合、replicationなしでRailsだけを起動するフォールバックは行いません。

#### Dokploy設定

- build type: Dockerfile
- Dockerfile path: `Dockerfile.prod`
- container port: `80`
- persistent volume mount: `/data`
- container command: Dockerfileの既定commandを使用
- 必須secret: `RAILS_MASTER_KEY`、Litestreamのaccess keyとsecret key
- Web Push使用時の必須環境変数: `VAPID_PUBLIC_KEY`、`VAPID_PRIVATE_KEY`、`VAPID_SUBJECT`
- 必須database path: `DATABASE_PATH`、`STORAGE_DATABASE_PATH`と、選択に応じた`QUEUE_DATABASE_PATH`／`CACHE_DATABASE_PATH`／`CABLE_DATABASE_PATH`
- 必須replica URL: primary、storageと、選択に応じたqueue／cableのLitestream URL
- 任意の調整値: `WEB_CONCURRENCY`、`RAILS_MAX_THREADS`、`DATABASE_POOL_SIZE`、`JOB_CONCURRENCY`、Thrusterのcache容量

production環境変数の実値や秘密情報を生成先リポジトリへ保存しません。Thruster/Pumaのport環境変数は生成せず、Dokploy側をcontainer port 80へ合わせます。

### `none`

`Dockerfile.prod`、`.dockerignore`、production用`bin/docker-entrypoint`、`Procfile.prod`、`litestream.yml`、Kamal、Dokploy固有設定を生成しません。`foreman`も追加しません。Rails標準のThruster Gemと`bin/thrust`、Puma設定、選択したSolid Queueの`bin/jobs`は維持します。

## Rails 8.1のSolid系既定値

Rails 8.1は、skip optionを指定しない場合に`solid_cache`、`solid_queue`、`solid_cable`をまとめて生成します。本プロジェクトではSolid QueueとSolid Cableがユーザー選択なので、Rails既定の一括導入をそのまま利用できません。

`rails new`開始前にSolid系のgenerator optionを確定し、標準の一括導入を`--skip-solid`で抑止したうえで、選択したcomponentだけを公式install generatorで導入します。Solid Cacheは既定で使用し、質問で無効化できます。

## Deviseと追加SIWEログイン

Devise 5.0.4と`devise-i18n`は常設し、Userは標準の整数`id`、`login_id`、`encrypted_password`、`remember_created_at`を持ちます。`login_id`はUser作成時に`SecureRandom.hex(10)`から未使用の20文字小文字hexを生成し、client入力を採用せず、永続化後の変更をmodel validationで拒否します。databaseの`NOT NULL`制約とunique indexを最終的な一意性境界として維持します。

会員登録はpasswordとpassword confirmationだけを受け付け、成功時はDeviseの自動ログイン状態を維持して`/users/sign_up/complete`へ遷移します。この認証必須画面とaccount設定だけが本人へ`login_id`を読み取り専用で表示し、保存を促す文面とコピー操作を提供します。関連・認可・監査は`users.id`だけを参照し、公開Profileと管理画面へ`login_id`を露出しません。email、password recovery列、`:recoverable`、`:validatable`は生成しません。

`additional_login_methods`へ`siwe`を選択した場合だけ`siwe-rb` 0.2.xと`:siweable`を追加します。`:siweable`はDeviseの公開module登録契約に従ってmodel、controller、routeを登録し、Warden strategyは追加しません。mapper拡張をroutes評価前に読み込み、成功時は紐付いた既存Userの`active_for_authentication?`を確認してDeviseの`sign_in`を呼びます。

`SiweIdentity`はUserごとに複数の名前付きEOA addressを保持します。登録時はpasswordや名前を入力させず、serverが`Wallet #<現在の登録数+1>`を設定します。名前の重複は許可し、一覧から分離された編集画面で後から変更できます。解除は編集画面へ混在させず、専用のresource詳細画面でcurrent passwordを検証してから実行します。一覧の各wallet rowは間隔を空け、編集と解除への遷移を個別に表示します。`SiweChallenge`はraw tokenのdigest、login/link purpose、link対象User、browser session binding、address、chain ID、server生成message、nonce、5分の期限、消費時刻をdatabaseで管理します。署名済みmessageからaddressを導出し、canonical originからdomainとURIを構成します。challengeの発行・検証はPOST＋CSRF、no-store、IP＋session rate limitで保護し、同一challengeの並行consumeは1件だけ成功します。RPC、ERC-1271、WalletConnect、外部SaaSは導入しません。
