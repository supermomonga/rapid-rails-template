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
| Profile名生成 | `haikunator` | 全構成でUser作成時の`screen_name`と`display_name`の既定値生成に使用する |
| 既定アバター生成 | `boring_avatars ~> 0.1.0` | 全構成でUser IDから決定的なSVGを生成する |

Rails 8.1では、SQLite、Puma、Propshaft、Importmap、Turbo、Stimulus、Minitestが標準構成に含まれます。これらをGemfileへ重複追加せず、対象の`rails new`オプションと生成結果を検証します。Tailwind CSSは`--css=tailwind`を指定し、Railsが提供する`tailwindcss:install`処理を利用します。

daisyUIはTailwind CSS 4用pluginとして、Application Templateのpost-bundleフェーズで`npm install --save-dev daisyui@latest`により導入します。生成された`package.json`と`package-lock.json`を管理し、`app/assets/tailwind/application.css`へ組み込みthemeを無効化した`@plugin "daisyui"`と`@plugin "daisyui/theme"`によるcustom themeを登録します。JavaScript配布は引き続きImportmapを使用し、Node.jsはJavaScript bundlerではなくTailwind CSS plugin依存のinstallとasset buildにのみ使用します。`node_modules`はGitおよびDocker build contextへ含めません。

Kamal用のproduction imageではbuild stageにNode.jsとnpmを導入し、lockfileに対して`npm ci`を実行してから`assets:precompile`を行います。生成済みCSSだけをfinal stageへ引き継ぎ、`node_modules`とNode.js runtimeはfinal imageへ含めません。

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

field radiusは`0.5rem`、box radiusは`0.75rem`、borderは`1px`、depthとnoiseは`0`に固定します。本文は16px・line-height 1.8、見出しはline-height 1.5、codeは14px・line-height 1.5とし、指定のsystem/Japanese font stackを使用します。本文へ`palt`を適用せず、`word-break: break-all`と`overflow-wrap: break-word`を設定します。補足文はopacityを重ねず`neutral`を直接使用して実効alphaを`0.55`に保ちます。入力欄はdaisyUI標準の`input`を使用し、独自のborder・focus・typography classは追加しません。buttonはdaisyUI標準の`btn`を使用し、サイズ変更が必要な場合は`btn-xs`から`btn-xl`までの公式size modifierを組み合わせます。標準card surfaceは`card card-border bg-base-100`を使用します。`.card-border`は幅と線種をdaisyUIの既定値に任せ、Tailwind CSSのutilities layerに置く`:where(.card-border)`で`border-color: var(--color-base-300)`だけを指定します。低specificityにすることで、`border-error`などのsemantic color modifierを維持します。

通常の文字付き操作button・button相当のlinkは、共通の`ApplicationHelper#action_button_classes(role)`で次のroleとclassを一対一に対応させます。未知のroleは明示的に失敗させ、既定roleへのfallbackは行いません。

| role | class | 用途 |
| --- | --- | --- |
| `:primary` | `btn btn-primary` | 作成、保存、登録など、その画面の主操作 |
| `:secondary` | `btn` | 編集、詳細、同格の代替操作 |
| `:quiet` | `btn btn-outline` | 戻る、キャンセルなどの低強調操作 |
| `:warning` | `btn btn-outline btn-warning` | pause、retryなど注意を伴う実行操作 |
| `:destructive` | `btn btn-outline btn-error` | 削除・解除への導線、または別の確認を挟む危険操作 |
| `:destructive_confirm` | `btn btn-error` | 専用の確認・再認証画面で不可逆処理を確定する操作 |

theme tokenの`secondary`はprimary色のhover・press用の色、button roleの`:secondary`は副操作の見た目、`page_actions_secondary`は補助的なページ操作の配置先を表します。同じ`secondary`という語を含みますが別の契約であり、slot名からbuttonの色を決めたり、`:secondary`へtheme tokenの`secondary`色を適用したりしません。

`:warning`は注意を促すsemantic colorを維持しつつ、画面内でオレンジ色の占有面積が過度に大きくならないよう`btn-outline`を必須とします。通常のコンテンツ操作へ塗りつぶしの`btn-warning`は使用しません。

文字付きのbuttonとbutton相当のlinkは、hoverしていない通常時にも背景または輪郭で操作可能な要素だと判別できる表示を必須とし、`btn-ghost`を使用しません。この規約は通知popover、受信者selector・badge、header、menu、dropdownなど`action_button_classes`を使用しないcompact用途にも適用します。`btn-ghost`は、accessible nameを持つベルやアバターなど、文字を持たない慣例的な操作triggerだけに限定します。色modifierを持たない`btn-outline`は、文字色を`base-content`のまま維持し、通常時のborderだけを`base-300`へ上書きします。`btn-primary`、`btn-secondary`、`btn-accent`、`btn-neutral`、`btn-info`、`btn-success`、`btn-warning`、`btn-error`のいずれかを併用するoutlineには適用せず、各semantic colorのborderを維持します。

daisyUIのAlertは、`alert-info`、`alert-success`、`alert-warning`、`alert-error`のいずれかを使用する場合に`alert-soft`を必須とし、すべての状態を淡い色面で一貫して伝えます。既定の塗りつぶしや`alert-outline`は使用しません。静的View、flash、JavaScriptによる状態切り替え、engineの上書きViewを同じ契約に含めます。JavaScriptで状態色を切り替える場合も`alert-soft`を維持します。badge、progress、button、cardのsemantic colorはこのAlert固有の規約の対象外です。

`DESIGN.md`は任意のCSS Custom Propertiesへ依存しない方針ですが、daisyUI custom themeとcomponent自体が公式の`--color-*`、`--radius-*`、`--size-*`、`--input-color`等をcontractとします。daisyUIのtheme・component contractに必要な変数だけを例外として使用し、独自の追加変数やView内のraw palette colorは定義しません。

### 標準View構成

生成アプリケーションには、共通application layout、認証用sub-layout、メニュー付き画面用の`with_menu` partial layout、account用sub-layout、admin用sub-layout、header、flash、footer、公開home、認証必須の`/account`を必ず生成します。全Viewは`data-theme="rapid-rails"`配下でdaisyUI componentとsemantic colorを使用します。

Viewはcomponent-firstで構築します。daisyUIに意図が一致するcomponentやpart、modifierがある場合は、Tailwind CSS utilityだけで同等のUIを再実装しません。headerは`navbar`、guest向けdesktopの`button`群、guest向けmobileと認証後の`dropdown` + `menu dropdown-content`、footerは内側幅をheaderと共有する`footer`と`footer-title`、homeの導入部は`hero`、情報ブロックは`card`、FAQはnativeの`details`を使う`collapse`、account navigationは`menu-title`と`menu-active`を含む`menu`、formは`fieldset`、`fieldset-legend`、`input`、`file-input`、`checkbox`、`button`、補助導線は`divider`と`menu`、通知は`alert`を使用します。

Rails 8.1.3の公式templateを基準に、`generate scaffold`用controllerと6 View、`generate controller NAME ACTION`用Viewを上書きします。生成アプリケーションの`lib/templates/rails/scaffold_controller`、`lib/templates/erb/scaffold`、`lib/templates/erb/controller`へ変更したtemplateだけを配置し、mailerなどの未変更copyは配置しません。scaffoldの一覧は主キー昇順で25件ずつPagy paginationを適用し、`table table-sm table-pin-rows`を`overflow-x-auto`で囲みます。paginationは共通`ApplicationHelper#pagination`が`with_pagination`と`pagination_item_classes`を使用し、Pagyの7枠seriesをdaisyUIの`join`と`btn join-item`で描画します。`with_pagination`は空でない`aria_label`、任意のsummary、右寄せした1段の`join`、navigation内だけの横overflowを担当します。`pagination_item_classes`は共通classとactive・disabled・square modifierを一元管理します。各engine固有の件数計算、cursor、URL生成は共通helperへ移しません。active・disabled状態と、accessible name付きHeroicons矢印を持つ正方形の前後操作もhelperが一括生成し、個別Viewでは再構築しません。paginationはaction button roleの対象外とし、daisyUI標準のbutton modifierへ従います。詳細・編集画面は`card`、属性表示は`list`、formは属性型に対応する`input`、`textarea`、`file-input`、`checkbox`を使用します。Rails標準のgenerator変数、添付ファイル、password digest、`dom_id`、route helperのcontractは維持します。scaffoldのindex、new、editにあるheader actionはpage actionsへ移さず、standalone scaffoldだけの例外として維持し、他のViewへ一般化しません。

全生成Viewの主見出しは`content_for :page_title`へ文字列を1回だけ設定し、Viewまたは`with_menu` layoutの`h1`とdocument titleから再利用します。document titleと`og:title`は通常ページで「page title | application name」、`page_title`を持たない公開homeだけapplication nameとします。主見出し直前のeyebrowは置かず、カードや機能紹介など主見出しではないsection headingは維持します。

account navigationはdaisyUIの`menu with icons`として構築し、各linkの先頭へHeroiconsの24px outline SVGを`size-5`で配置します。マイページには`home`、常設のプロフィールには`user-circle`、アカウント設定には`cog-6-tooth`、Web Push使用時の通知には`bell`を使用し、SVGは装飾要素として`aria-hidden="true"`にします。管理者には`UserPolicy#overview?`を満たす場合だけ、`/admin`のOverviewへ移動する「管理画面」を単一のbridge linkとして追加し、account sidebarと通常画面のheader dropdownへ同じpartialから表示します。accountとadminの`with_menu` navigationは960px以下でカテゴリ名を横スクロール領域の上へ固定表示し、リンク一覧をdaisyUIの`menu-horizontal`で1段表示します。はみ出したリンクだけをnavigation内で横スクロールさせ、page全体には横overflowを発生させません。961px以上ではカテゴリ名を`menu-title`として含む`menu-vertical`へ戻し、従来の2column sidebarを維持します。headerの認証後dropdownは、admin controllerでは見出し「管理画面」と管理項目だけを表示し、それ以外ではaccount項目と管理者限定bridge linkだけを表示します。ユーザー情報はlinkやbuttonではなく直接の`menu-title`として表示し、hoverやactiveの対象にしません。ログアウトの前は空の`li`によるdaisyUI `menu`標準のseparatorで区切り、ログアウトにはHeroiconsの`arrow-right-start-on-rectangle`を表示します。認証後headerでは常にdaisyUI `avatar`をtriggerにします。サイト全体のheaderにhome導線があるため、account navigation内へ「ホームへ戻る」は重複配置しません。

component内部の高さ、padding、配置はdaisyUIの既定値を優先します。特に`menu`直下のitemへ`min-h-*`や`p-*`を追加せず、サイズ変更が必要な場合は`menu-sm`から`menu-xl`までの公式modifierを選びます。Tailwind CSS utilityはpage placement、responsive layout、または`DESIGN.md`で値が明示された見た目の調整だけに使用し、component既定値を上書きする場合は理由を設計文書とテストへ残します。

「管理画面」のbridge linkは、選択機能によって増減するaccount項目をすべて並べた後の末尾へ配置する。

- `/`は追加ログイン方法にかかわらず公開する。
- `/account`は認証必須とし、account sub-layoutで表示する。
- Userと1対1のProfile、`screen_name`、`display_name`、`avatar`、表示／編集／更新画面を全構成へ生成する。Active StorageはAction Textとともに常設し、Boring AvatarsとProfileの添付画像機能も常設する。
- 画像未設定時はUser IDの文字列表現から`beam` variantのBoring Avatarを生成し、themeのbase-100、primary、base-200、secondary、base-300に対応する5色を使う。seedはDBへ保存しない。設定済み画像を削除した場合は同じ既定アバターへ戻す。
- `haikunator`を常設し、User作成と同時に必須かつ一意な`screen_name`を生成し、そのCamelCaseを`display_name`の初期値とする。
- API機能を有効にした場合は、account navigationへ「APIキーの管理」を追加し、credentialの一覧、作成、詳細、名称変更、削除、secret再発行をaccount sub-layoutで提供する。一覧は`table`、formは`fieldset`と`input`、secretの一度限りの表示は`alert`、操作は`button`を使用する。
- Passkeyのlogin・account登録はauthentication sub-layout、認証後のPasskey管理はaccount settings sub-layoutで表示する。ユーザーID、password、password recoveryは生成しない。認証画面ではPasskeyを既定の認証方法として`:primary`、SIWEを選択した場合のWallet署名を代替手段として`:secondary`で表示し、この優先順位を画面ごとに変えない。loginとaccount登録を切り替える案内文とlinkは`content_for :authentication_switch`へ渡し、認証方法をまとめる主cardとは1rem離した同幅の別cardに表示する。案内文は主cardの説明文と同じ`text-sm text-base-content/70`とし、切替cardは主cardと同じ`p-6 sm:p-8`を使用する。認証方法間ではない空のdividerを置かない。
- ブラウザ側はWebAuthn Level 3の`parseCreationOptionsFromJSON`、`parseRequestOptionsFromJSON`、credentialの`toJSON`を使用する。未対応ブラウザは利用不可を明示し、独自変換のfallbackは追加しない。
- SIWE選択時だけsignup・login画面へ明示的な署名buttonを追加する。全SIWE操作でEIP-6963 Providerを収集し、複数Providerの場合は共通`with_modal`による名前一覧から選択したProviderだけを接続・署名に使用する。EIP-6963非対応時だけ`window.ethereum`を使用する。「アカウント設定」の`tabs-lift`でPasskeys、EVMウォレット、アカウント削除を切り替え、解除・削除は操作ごとの別資格情報による再認証画面へ分離する。
- bodyのpage背景は`base-100`、main content sectionは`base-200`とし、cardは`base-100`へ戻して境界を明示する。
- headerとfooterは全幅のbackground・borderと、`max-w-6xl`の内側componentを分離する。メニュー付き画面はRailsの`render layout:`で`with_menu` partial layoutを適用し、accountとadminのsub-layoutが`content_for :with_menu_navigation`へ固有menuを1回だけ設定して本文をlayout blockとして渡す。`with_menu`は呼出元を判定せず、`max-w-6xl`、水平padding、`220px + minmax(0, 1fr)`のgrid、名前付きnavigation、`content_for(:page_title)`の主見出し、layout blockの本文を配置する。961px未満では1列へ切り替え、左ペインの`menu`を本文より先に表示する。
- ページ全体に作用する追加、単一controlの簡易絞り込み、一括操作はViewから`content_for :page_actions_primary`または`content_for :page_actions_secondary`へ渡す。primaryは基本操作、secondaryは簡易絞り込みやapplication/server選択などの補助操作とする。slotは配置する操作群だけを表し、buttonのroleや配色を決定しないため、primary側へ置く一括削除も`:primary`ではなく操作の意味に対応するroleを使用する。複数fieldまたは複数行になる複雑な検索formはpage actionsへ入れず、content areaの`card card-border bg-base-100`内へ配置する。個別model・table row・formに属する編集、削除、pause、run、保存、戻る操作は移動しない。共通rendererは未指定slotを出力せず、複数回設定されたfragmentを各列内で縦に並べる。640px未満ではsecondaryからprimaryの順に1列、640px以上では左secondary・右primaryの2列とする。
- card、form、modal、row内のaction groupは右寄せし、狭幅では折り返せるようにする。DOM順は低強調から高影響の`:quiet`、`:secondary`、`:warning`、`:primary`または`:destructive`とし、その画面の最終操作を右端へ置く。専用の確認・再認証画面では`:destructive_confirm`を最終操作とする。daisyUIの`card-actions`・`modal-action`を優先し、通常の文字付き操作をtable row内だけ小さくする`btn-sm`は使用しない。
- `action_button_classes`のcompact例外は、通知popover、受信者selector・badge、inputへ連結するCopy操作、header、menu、dropdown、icon-only button、modal backdrop、Wallet Providerのmenuに限定する。これらは該当するdaisyUI componentとmodifierを直接使用し、文字付き操作には通常時から操作面が分かるmodifierを指定する。例外を通常のcontent actionへ広げない。
- `with_menu`は本文blockを先にcaptureしてタブ有無を確定し、タブなしのpage actionsだけを主見出し直下の`card card-border bg-base-100`と`card-body p-3`へ配置する。タブなしページの最外周表示面となる標準`.card.card-border > .card-body`も`p-3`とし、activeな`tab-content`と内部余白を0.75remへ統一する。入れ子のcard、error variant、tableを端まで表示する意図的な`p-0`、`with_menu`外のcardは対象外とする。`with_tab`はactiveな`tab-content`の先頭へpage actionsをcardなしで配置して内部markerを設定し、`with_menu`による二重出力を防ぐ。両slotが空ならcardもaction containerも生成しない。
- account sub-layoutの左ペインにはユーザー向けmenuと、`UserPolicy#overview?`を満たすUserだけに表示する単一の管理画面bridge linkを末尾へ置き、個別の管理項目は混在させない。admin sub-layoutの左ペインには見出し「管理画面」と管理menuを表示し、全管理項目の後の末尾にだけマイページへのbridge linkを置く。現在のControllerに対応する管理linkは`menu-active`と`aria-current="page"`で示す。
- 複数Viewで共通する階層メニューは個別Viewへ複製せず、その画面群の機能単位nested layoutで1回だけ定義する。`with_menu`が主見出しを描画してからnested layoutを本文blockとして受け取るため、表示順は主見出し、subnavigation、本文となる。
- tabpanelを伴うタブは`ApplicationHelper#with_tab`だけで生成する。helperは各tabのoptionalな`is_active` lambdaを優先し、未指定時は`request.path.start_with?(path)`で候補を判定する。複数候補では最長pathを選び、同長競合または候補なしは明示的に失敗させる。必要な場合だけoptionalな`size:`でdaisyUI公式の`tabs-xs`から`tabs-xl`を選ぶ。Railsの`capture`で取得した本文はactiveな`tab`の直後へ1件だけ`tab-content sticky [contain:inline-size] bg-base-100 border-base-300 p-3`として置く。stickyなtabpanelの上borderが共有境界へ重なってもactive tabの下へ線が出ないよう、active tabへ`z-10`を付ける。inline-size containmentによりtabpanel本文のmax-content幅をtablistの必要幅から除外する。`tabs tabs-lift min-w-max`を`overflow-x-auto`で囲み、狭幅でも折り返さず横スクロールできるようにする。inactive用の空tabpanelや個別Viewの幅補正は生成しない。各画面の最外周へ同じbase borderを持つcardは重ねない。tabpanelを伴わないtab形式selectorは対象外とする。
- native dialogを使うdaisyUI modalは`ApplicationHelper#with_modal`だけで生成する。helperは一意な`id`、title、optionalなdescription、block本文、optionalなactions、dialog用data属性を受け取り、`modal`、`modal-box`、`modal-action`、`modal-backdrop`、ARIA参照を一括生成する。backdrop用`form[method=dialog]`を通常formへ入れ子にしないため、modal helperの出力は通常formの外へ置く。各Viewで同じmodal shellを組み立てず、helperはtriggerや個別Stimulus controllerの動作を担当しない。
- Cropper.js 2.1.1は全構成でImportmapの公式`pin` commandによりtransitive dependencyごと`vendor/javascript`へ固定し、実行時CDNとJavaScript bundlerを使用しない。汎用`image_crop` Stimulus controllerはoptionalなアスペクト比と出力幅・高さ、初期coverage、許可MIME type、容量・寸法上限、lossy品質をvaluesで受け取り、画像移動、zoom、reset、canvas出力、File置換、Object URLとCropper lifecycleを担当する。アスペクト比未指定時は自由cropとし、プロフィールViewだけが1:1と512×512を設定する。変換前のraw画像はformへ残さず、設定不正や変換失敗時にraw uploadへfallbackしない。
- `640px`以下をmobile、`960px`以下をtablet、`961px`以上をdesktop layoutとして扱う。desktopとmobileの両方で1columnへ縮退できることを必須とする。44pxのtouch targetを満たすためにcomponent itemへ一律の`min-h-*`を追加せず、必要な場合はdaisyUIの公式size modifierまたはtheme tokenでcomponent全体として調整する。

### 管理画面Overview

`/admin`はIDを持たない単一画面として`Admin::OverviewController#show`へ割り当て、`Admin::BaseController`の認証と`UserPolicy#overview?`の管理者認可を適用します。`OverviewsController`や`Overview` modelは生成しません。Overviewは全ユーザー数、admin roleを持つ重複なしのUser数、`created_at >= 30.days.ago`のUser数、公開FAQ数、管理対象Page数をrequestごとに集計し、cache、期間切替、graph、詳細drill-downは追加しません。

基本統計は`card card-border bg-base-100`内のdaisyUI `stats`、`stat`、`stat-title`、`stat-value`で表示し、390pxでは1列、広幅では2〜3列へ配置します。admin navigationの先頭には「概要」を置き、`admin/overview`で`menu-active`と`aria-current="page"`を設定します。

### Action Text、固定ページ、FAQ、footer設定

Action Text、Active Storage、Active Storage DB、Lexxyは選択式にせず、すべての生成アプリケーションへ導入します。Action Textの公式install generatorでActive Storageのmetadata／attachment migrationと添付表示partialを生成し、`active_storage_db`の公式migration taskでファイル本体用migrationを生成して`db/storage_migrate`へ分離します。Active Storage DB engineを`/active_storage_db`へmountし、development、test、productionのActive Storage serviceをすべて`:db`に設定します。Active Storageのblob metadataとattachmentはprimary database、ファイル本体は専用storage SQLite databaseへ保存し、Disk serviceへ暗黙に切り替えません。

Active Storageのvariant processorは全環境で`:vips`、variant trackingは有効、route resolverは`:rails_storage_proxy`へ固定します。Rails標準生成物の`image_processing ~> 1.2`を利用し、Kamal用runtime imageには`libvips`を含めます。Profile avatarは40×40の`header_avatar`と64×64の`profile_avatar`だけを`preprocessed: true`のnamed variantとして定義し、attachment commit後にActive Storage標準の`TransformJob`で非同期生成します。profile更新responseは変換完了を待たず、任意の変換hashをViewへ記述しません。attachmentとblob metadataはprimary SQLite、元画像と処理済みvariant本体はActive Storage DBの専用storage SQLiteをsource of truthとします。

ユーザーupload画像のnamed variantは非同期preprocessを標準とし、複数画像・複数variantの変換をrequest内で同期実行しません。生成中のvariantへrequestが競合する可能性はActive Storage標準のbest effortとして許容します。variant完成前の公開を禁止する機能要件が生じた場合は、そのdomain modelに限定した`processing`から`published`への状態遷移を設計し、Active Storage内部patch、汎用single-flight、元画像fallbackは追加しません。

生成アプリをDocker外で開発・testするhostにもlibvips runtimeが必要です。macOSでは`brew install vips`など、対象OSのpackage managerでlibvipsを明示的に導入し、`Vips::Image`が実画像をdecodeできることをtestで確認します。

Active Storageのblobとrepresentationは公式proxy controllerから配信します。初回requestはThruster、Puma、Rails、Active Storage DBを通り、Railsが`public`かつ`immutable`なresponseを返します。同じsigned URLがThrusterのmemory cacheに残っている間はThrusterが直接返却します。生成済みvariantはlibvips処理を省略しますが、Thruster cacheがcoldならRailsとSQLiteの読出しは発生します。Action Textのoriginal、download、削除とavatar policyは分離し、global proxy resolverでも各契約を検証します。

Thrusterのcache既定値は全体64 MiB、1 responseあたり1 MiBです。process再起動、eviction、上限超過、Range requestではcacheを利用できません。このtemplateはCDN、永続cache、独自cache middlewareを追加しません。Active Storageのproxy URLは恒久的で、URLを知る利用者へ公開されるため、認証必須の添付は対象外です。

Importmapへ`lexxy`と`@rails/activestorage`を登録します。管理formはRails標準の`rich_text_area`を使用し、Rails 8.1向けLexxy overrideでeditorを置き換えます。公開本文はAction Text content layoutを`lexxy-content`で包み、Lexxy stylesheetと同じ表示規則を適用します。

公開固定ページは`/about`、`/corp`、`/manual`、`/terms`、`/privacy`、`/transaction-law`とし、routeごとの固定slugを共通の`PagesController#show`へ渡します。`Page`のslugはこの6値へ限定し、titleとともにseedで冪等作成します。`corp`には運営者名、設立日、代表者、適格請求書発行事業者登録番号の表を、`terms`、`privacy`、`transaction-law`には汎用的な法的文書のひな形を、生成時のdefault localeに対応する日本語または英語で初回作成時だけseedします。seed再実行時は空の本文を含む既存recordを上書きしません。法的文書の本文は運営者が公開前に実態へ合わせて編集するひな形であることと、置換が必要な項目を明示します。管理者は本文だけを更新でき、固定ページの作成、削除、slug、titleの変更は提供しません。存在しない固定recordや未知slugを別ページへ戻すfallbackは設けません。

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

`haikunator`はapplication Gemとして常設します。`screen_name`は`Haikunator.haikunate(9999, "_")`の候補から既存値と衝突しない値を採用し、そのCamelCaseも`display_name`として未使用であることを確認して同時に設定します。model validationに加えてdatabaseの`NOT NULL`制約とunique indexで不変条件を保証します。

`boring_avatars`は全構成でRails bindingを明示的に読み込みます。共通View helperがActive Storage添付を優先し、未添付時だけ`User#id.to_s`をseedとしてSVGを生成します。SVG内部IDはgemの衝突回避へ委ね、avatar seed用の永続化項目は追加しません。theme色はserver-side generatorが要求する16進色の定数として一元化し、CSS themeとの一致を契約テストで保証します。

### アプリ内通知

全構成へ`Notification`と`NotificationDelivery`を生成します。通知本文は`has_rich_text :message`でAction Textへ保存し、固定ページ編集と同じ`form.rich_text_area`をLexxy editorとして表示します。装飾を除いたプレーンテキストをtrimした長さは1〜140文字に限定します。通知は必須の公開日時、下書き状態、全ユーザーまたは個別ユーザーの通知先を持ち、公開範囲を`draft = false AND published_at <= cutoff`に限定します。`NotificationDelivery`は個別通知にだけ許可し、通知とUserの組をdatabaseの一意制約で保護して通知削除時にcascadeします。下書きでない個別通知は予約公開を含め受信者を1人以上必須とします。個別通知は通知保存と同じtransactionで対象差分を同期し、継続対象の既読日時を保持します。全体通知へ切り替えた場合は既存の個別配信行を削除し、全UserのID取得や配信行のbulk insertは行いません。

Userの`global_notifications_read_at`はUser作成時の`created_at`と同じ値で初期化し、全体通知の未読を`published_at > global_notifications_read_at`で判定します。これにより、後登録のUserも過去の全体通知を一覧表示できますが、User作成前の通知は未読になりません。最終確認日時は、「お知らせ」表示取得時のcutoff以前を対象とする条件付き単一SQLで単調に更新し、並行する古いrequestで巻き戻しません。既読後の本文編集、下書き化・再公開、通知先の切替えは未読を再生成せず、`published_at`を明示的に後へ変更した場合だけ判定へ影響します。過去の`published_at`を指定して後から公開した全体通知は一覧には表示されますが未読にはなりません。

認証済み画面のheaderにはHeroiconsのbellと、公開済みの未読個別通知、または最終確認日時より新しい公開済み全体通知がある場合だけdaisyUIの`indicator`と`status`を表示します。native Popover APIとdaisyUI `dropdown`内のTurbo Frameは閉じている間に通信せず、開くたびに初期タブの「あなたへの通知」へ戻って最新10件を読み込みます。popoverと`/notifications`は`tab=personal|announcements`を受け付け、「あなたへの通知」に個別配信、「お知らせ」に全体通知を公開日時・ID降順で表示します。省略時は`personal`、不正値は`400 Bad Request`とし、一覧はタブ別に25件ずつpaginateします。個別通知のみ既読表示・個別既読・一括既読を持ちます。「お知らせ」のGET取得では最終確認日時を変更せず、表示成功後の専用`PATCH /notifications/global-read`が取得時のcutoffまで単調更新し、Turbo Streamでnavbarとタブの未読表示を更新します。previewや読込失敗では更新せず、失敗時は未読表示を残して再試行できるエラーを表示します。popoverの「もっと見る」は現在タブを履歴へ引き継ぎます。管理CRUDとProfile表示名による最大20件の受信者検索はAction Policyでadminに限定し、User IDは画面へ表示しません。管理一覧の対象表示は全体通知を「全ユーザー」、個別通知を受信者数とし、受信者selectorは個別通知の場合だけ有効にします。

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

追加ログイン方法にかかわらず、Web Pushを有効にした場合だけDevise認証必須の`/web-push`を生成し、account navigationの独立項目「Web Push設定」から開きます。アプリ内通知の`/notifications`やheader popover、`Notification`、`NotificationDelivery`とは共有しません。全体通知の日時カーソルはWeb Pushの配信対象や過去配信には使用しません。設定画面はdaisyUIの`card`、`toggle`、`btn`、`alert`とHeroiconsのbellを表示します。通知許可はtoggleをONにしたユーザー操作内だけで要求し、unsupported、default、granted、denied、通信中、失敗を画面へ反映します。

### Roleと認可

生成アプリケーションには固定roleを複数付与できる`UserRole`とAction Policyのpolicy基盤を常に生成します。初期roleは`admin`だけとし、一般Userはroleを持ちません。`UserRole`は内部識別子である`user_id`と文字列`role`を持ち、組み合わせの一意制約、外部キー、`NOT NULL`、許可roleのdatabase check constraintで不変条件を保証します。role定義はコードとmigrationで管理し、管理画面からrole種別そのものを追加・編集しません。

`User`は`has_role?`、`grant_role!`、`revoke_role!`を公開し、role付与を冪等にします。一般の登録・アカウント更新parameterへroleを含めず、role変更はAction Policyで保護された管理画面に限定します。複数roleの権限は許可を加算し、role階層と明示denyは持ちません。

管理画面は`/admin/users`に数値ID、常設Profileの40×40アバターと詳細画面への表示名リンク、roleをページング表示します。一覧にはrole操作を置かず、`/admin/users/:id`でUser ID、WebAuthn ID、登録日時、Profile、roleを表示し、確認付きの`admin`付与・解除を行います。付与はwarning、解除はdestructiveのbutton roleを使用し、対象の表示名を確認文へ含めます。`/admin/users/:id/edit`では既存Profileフォームと画像policyを再利用し、表示名、スクリーンネーム、アバターを更新できます。User本体とPasskey・walletは参照または管理対象に含めず、更新parameterにも受け入れません。自分自身の`admin`解除と最後の`admin`解除・削除を拒否します。developmentでは既存のadminが0人の場合に新しく作成されたUserへadmin roleを自動付与し、全部入りsampleのseed Userだけは明示的に除外します。既存Userへの手動付与には`users.id`を引数に取る`roles:grant_admin[user_id]` taskを使用し、local seedは`ADMIN_USER_ID`を使用します。

## テスト用Gem

```text
capybara
capybara-playwright-driver
factory_bot
factory_bot_rails
```

Playwright driverはChromium・headlessへ固定し、`playwright-ruby-client`が公開する互換CLI versionを`package.json`へ導入します。実行時は生成アプリケーションの`node_modules/.bin/playwright`を明示し、`playwright install chromium`でbrowser binaryを準備します。必要な実行ファイルがない場合にSeleniumへ戻すフォールバックは設けません。

UIエビデンスはCapybaraのroute遷移・入力・表示確認と、Playwright native pageのfull-page screenshotを組み合わせます。CDP virtual authenticatorによるPasskey登録とリスク警告、複数Passkey管理・削除時再認証、SIWE固有差分、画像配信差分を1400×900と390×844で撮影します。SIWE差分はdatabase challengeと署名検証で同じUserへsessionを作成し、テスト専用認証routeは生成しません。

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

生成時に`# typed: true`以上を付ける対象はcontroller、concern、helper、model、policy、service、job、mailer、task、validator、application-owned `lib`、config、test、`db/seeds.rb`です。configではPuma、Importmap、Rails CI、Maintenance Tasksが`instance_eval`するreceiverをRuby本体の`T.bind`で明示し、RailsがApplication subclassへ動的に委譲する`config_for`だけを`framework_bindings.rbi`で表現します。migration、schemaはRails DSLと実行順依存が強いため`typed: false`に留めます。`.rake`内にapplication logicを置かず、`roles:grant_admin`は`typed: strict`な`AdminRoleGrant`を呼び出します。

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

productionではPuma pluginを有効化せず、Solid Queue使用時だけKamalの`worker` roleで`bin/jobs --mode async`を起動します。Web roleとはコンテナを分離し、worker、dispatcher、schedulerを同じSolid Queue supervisorで管理します。

`solid_queue:install`が生成する`config/recurring.yml`の標準cleanupを維持します。`preserve_finished_jobs`は既定の`true`、`clear_finished_jobs_after`は既定の1日とし、毎時12分に`SolidQueue::Job.clear_finished_in_batches(sleep_between_batches: 0.3)`を実行します。cleanupは`finished_at`が保持期間より古い完了ジョブだけを対象とします。失敗ジョブは`solid_queue_failed_executions`に残り、管理者または運用者がretryかdiscardを行うまで削除しません。既存の`bin/jobs --mode async` supervisorがworker、dispatcher、schedulerを起動するため、cleanup専用processは追加しません。

## Mission Control Jobs

`job_operations=enable`かつ`active_job=solid_queue`の場合だけ、Mission Control Jobs 1.1.0を導入します。engineは`/admin/jobs`だけへmountし、root直下の`/jobs`や別pathへ公開しません。queue一覧、状態別job、worker、定期task、失敗内容、単体・一括retry/discardなど、Solid Queue adapterが提供する操作を使用します。

`MissionControl::Jobs.base_controller_class`には`Admin::JobOperationsController`を設定します。このcontrollerは既存`Admin::BaseController`を継承し、全engine actionを`JobOperationPolicy#manage?`で認可します。追加ログイン方法にかかわらずDeviseの`current_user`を既存Action Policy contextへ渡し、controller内でroleを直接判定しません。Mission Control標準のHTTP Basic認証は明示的に無効化し、別系統の認証は追加しません。

Mission Controlの公式ViewはBulma classを出力するため、Rails 8.1 Enginesの公式View lookup順序を利用し、Mission Control Jobs 1.1.0向けのhost Viewでlayout、application/server選択、section tab、flash、queue、状態別job、filter、worker、定期task、詳細、paginationをshadowします。Bulma stylesheetや専用CSSは生成せず、既存Tailwind CSS 4／daisyUI 5の`tabs`、`tab-content`、`card`、`card-border`、`table`、`badge`、`btn`、`fieldset`、`alert`、`collapse`、`mockup-code`、`join`へ統一します。上書きViewの見出し、tab、table、状態、日時、操作、確認文、ARIA labelは生成するja/en localeを正本とします。engineの英語専用I18n設定は専用layoutの描画範囲だけ通常のI18n設定へ切り替え、`ensure`で復元することで、hostのheader、footer、HTML metadataを既定localeのまま維持します。engine controller由来の操作後通知と例外message、route、controller、adapter、retry/discard/pause/resume/run操作契約は変更しません。専用layoutはlocaleに対応したqueue、状態別job、worker、定期taskのsection tabを既定sizeの`with_tab`へ渡し、desktopのsection tabを1段へ収め、狭幅ではhelperのscroll container内で横スクロールさせます。画面固有の小型modifierは追加せず、操作buttonもdaisyUI標準のsizeとtypographyを使用します。`current_section`を参照するlambdaでactiveを判定してengine本文blockを直後のtabpanelへ渡します。各engine Viewは実際の画面名を`page_title`へ設定します。application/server選択はtabpanelを伴わないselectorなのでhelper対象外とし、tab content本文内に残します。通常画面ではhost Importmap、engine画面ではMission Control Importmapだけを出力し、専用layoutから既存admin layoutへnested renderします。document titleは翻訳済みpage titleとapplication nameを組み合わせます。

Mission Control JobsとMaintenance Tasksは役割を分けます。Mission Control Jobsはqueueとjobの監視・retry/discard、Maintenance Tasksは運用taskの開始・進捗管理を担当し、`/admin/jobs`と`/admin/maintenance_tasks`のroute、policy、navigationを独立させます。

## Maintenance Tasks

`maintenance_tasks=enable`かつ`active_job=solid_queue`の場合だけ、Shopify `maintenance_tasks` 2.17.0を導入します。公式`maintenance_tasks:install` generatorが提供するmigrationをそのまま使用し、`maintenance_tasks_runs`で実行履歴、status、cursor、arguments、metadata、job ID、error class/message/backtraceを管理します。同じ情報を保持する独自modelやaudit tableは追加しません。

engineは`/admin/maintenance_tasks`へだけmountし、`Admin::MaintenanceTasksController`を`MaintenanceTasks.parent_controller`へ設定します。parent controllerは既存`Admin::BaseController`を継承し、全engine actionを`MaintenanceTaskPolicy#manage?`で認可します。metadataには`triggered_by_user_id`として`users.id`を保存し、追加ログイン方法にかかわらずDeviseの`current_user`を利用します。

engineのroute、controller、helper API、Run操作は2.17.0公式実装を維持し、専用layoutから既存admin layoutへnested renderします。Bulma stylesheetは読み込まず、Bulma classを出力するtask、run、errorのViewと表示helperをhost側でshadowして、既存Tailwind CSS 4／daisyUI 5のcard、badge、collapse、form、alert componentへ統一します。3秒ごとの`data-refresh`更新はhostのStimulus controllerで行い、外部stylesheet用CSP例外やinline scriptは追加しません。

Maintenance TaskはKamalの既存Solid Queue `worker` roleで実行し、専用roleを追加しません。

生成アプリには`Maintenance::CountdownTask`をサンプルとして含めます。Taskのcollectionは10から1までの整数を降順で返し、各iterationは対象の数値をapplication logへ記録します。これにより永続データを変更せず、queue、進捗、一時停止、再開、完了の流れを確認できます。

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

## Kamal V2 deployment

デプロイは全構成でKamal V2へ固定し、選択optionは設けません。Rails標準のDocker/Kamal生成を有効にしたうえで、Kamal `~> 2.11`と`minimum_version: 2.11.0`を固定します。対象topologyは単一Linux host・単一Web replicaです。

`Dockerfile`はRails標準構成を基礎に、Ruby 4.0.0のmulti-stage build、Node.js/npmによるasset build、libvips、jemalloc、YJIT、Thrusterを維持します。LitestreamとForemanはアプリimageへ含めません。Webはprimary role、Solid Queue使用時だけ`worker` roleを生成します。

production SQLiteは`<app_id>_<destination>_storage` named volumeの`/rails/storage`へ配置し、`production`と`staging`を分離します。Kamalはdestination指定を必須にします。

| database | path | 条件 | Litestream |
| --- | --- | --- | --- |
| primary | `/rails/storage/production.sqlite3` | 常時 | 対象 |
| storage | `/rails/storage/production_storage.sqlite3` | 常時 | 対象 |
| queue | `/rails/storage/production_queue.sqlite3` | Solid Queue使用時 | 対象 |
| cache | `/rails/storage/production_cache.sqlite3` | Solid Cache使用時 | 対象外 |
| cable | `/rails/storage/production_cable.sqlite3` | Solid Cable使用時 | 対象 |

SQLite共通設定は`transaction_mode: immediate`、`timeout: 20000`とし、connection poolは`DATABASE_POOL_SIZE`、未指定時は`RAILS_MAX_THREADS`を使用します。storage、queue、cache、cableはそれぞれ専用migration pathを使用します。

### Litestream Accessory

Litestream 0.5.15をKamal Accessoryとして起動し、Web・Workerと同じdestination別named volumeをuser `1000:1000`でmountします。replicaはCloudflare R2のS3互換endpointへ固定し、各databaseは同じdestination bucket内の別object prefixを使います。

| 用途 | 環境変数 |
| --- | --- |
| Cloudflare account | `CF_ACCOUNT_ID` |
| destination bucket | `LITESTREAM_R2_BUCKET` |
| access key | `R2_ACCESS_KEY` |
| secret key | `R2_SECRET_KEY` |

endpointは`${CF_ACCOUNT_ID}.r2.cloudflarestorage.com`、regionは`auto`です。object prefixは`primary`、`storage`、条件付き`queue`・`cable`です。資格情報の正本は人間ユーザーのaccount全体で一意性を確認したdestination別vault内のitemとし、service accountには両vaultの`read_items,write_items`だけを付与します。`.kamal/secrets.production`・`.kamal/secrets.staging`にはKamal公式1Password adapterが使うservice account ID、vault ID、item IDだけを生成します。共通secretは`.kamal/secrets-common`に置きます。ローカルWrangler v4とGumを使う`mise exec -- bin/rails litestream:configure:r2`がservice account認証、vault、bucket、Cloudflare account-owned API token、item、参照生成を担当します。初回に1Password service accountを作成した場合は、そのservice account tokenだけをgit/Docker管理外かつ`0600`の`mise.local.toml`へ平文保存して終了し、再実行時にはvaultを追加作成せず構成を続けます。

Cloudflare token作成用の`CLOUDFLARE_INITIAL_API_TOKEN`は、対象accountのSuper Administratorが作成し、dashboard上の`Account API Tokens: Edit`（API上の`Account API Tokens Write`）だけを持たせて実行環境から毎回渡し、保存しません。作成確認画面では対象accountと権限を確認します。未設定なら最小権限のToken Template URLを表示して無変更で正常終了します。Wranglerのaccount選択直後にtokenのactive状態、所有account、単一account resource、単一permissionをAPIで照合し、不一致や認証拒否では1Password・R2・repositoryを変更する前に停止します。destinationごとのtoken名は`<正規化済みapp_id>-r2-<destination>`、権限は対象bucketの`Workers R2 Storage Bucket Item Write`だけです。同名tokenがCloudflareと1Passwordの両方で完全一致する場合だけ再利用し、重複・無効・policy差異・secret欠落や不一致では自動rotationせず停止します。Cloudflare token本体は1Password itemの`CLOUDFLARE_R2_API_TOKEN`へconcealed fieldとして保存し、token IDとtoken本体のSHA-256から派生したS3資格情報も同じitemへ保存します。Kamalが取得するのは`CF_ACCOUNT_ID`、`LITESTREAM_R2_BUCKET`、`R2_ACCESS_KEY`、`R2_SECRET_KEY`だけです。

各DBへ`restore-if-db-not-exists`を設定します。空volumeかつbackupがある場合だけ起動時に復元し、既存DBは上書きしません。初回でbackupが存在しない場合は新規DB作成へ進み、それ以外の復元・接続エラーではAccessoryを失敗させます。Litestreamは復元とDB openの後にcontrol socketを公開し、Web entrypointはsocketのstatus応答後に`db:prepare`、Workerはstatus応答後に`bin/jobs`を開始します。

Accessoryは通常の`kamal deploy`では更新されないため、設定・image・secret変更時はdestinationを付けて`mise exec -- bin/kamal accessory reboot litestream -d DESTINATION`を実行します。

### 確認付き手動復元

`mise exec -- bin/kamal-restore`は`--destination=production|staging`を必須とし、最新時点、`--timestamp=RFC3339`によるpoint-in-time、`--plan`によるdry-runを提供します。書き込み操作はTTYと`RESTORE <app_id> <destination> <target>`の完全一致入力を必須にし、確認回避やforce optionは提供しません。

確認後はmaintenance化、Web/Worker停止、全DBの`sync -wait`、Accessory停止、deploy lock取得、全DBの一時領域へのrestoreとfull integrity check、同一volume内renameの順で処理します。primary、storage、条件付きqueue/cableを常に一組で扱い、部分的な復元は許可しません。切替途中の失敗は補償renameで元へ戻します。

復元前DBとWAL/SHM/journalは操作ID別に保持し、destination付きの`mise exec -- bin/kamal-restore --rollback=OPERATION_ID`で確認付きrollbackを行います。復元中はdestination別remote markerと`pre-deploy` hookで新規deployを拒否し、破壊的な切替中はdeploy lockを保持します。切替後の起動失敗では自動rollbackせず、サービスとmarkerを停止状態で残して調査可能にします。

## Rails 8.1のSolid系既定値

Rails 8.1は、skip optionを指定しない場合に`solid_cache`、`solid_queue`、`solid_cable`をまとめて生成します。本プロジェクトではSolid QueueとSolid Cableがユーザー選択なので、Rails既定の一括導入をそのまま利用できません。

`rails new`開始前にSolid系のgenerator optionを確定し、標準の一括導入を`--skip-solid`で抑止したうえで、選択したcomponentだけを公式install generatorで導入します。Solid Cacheは既定で使用し、質問で無効化できます。

## Devise、Passkey、追加SIWEログイン

Devise 5.0.4、`devise-i18n`、`webauthn ~> 3.4`、`browser ~> 6.2`は常設し、Userは標準の整数`id`、ランダムで一意かつ変更不可の`webauthn_id`、`remember_created_at`を持ちます。`:database_authenticatable`、`:registerable`、`login_id`、`encrypted_password`、password recoveryは生成しません。`:passkey_authenticatable`と`:rememberable`を使い、検証成功後はDeviseの公開`sign_in` APIでsessionを確立するとともに、検証済みcredentialの型とIDを認証元としてsessionへ記録します。

Passkeyはdiscoverable credentialとして複数登録でき、platformとcross-platform authenticatorの両方を許可します。登録時に名称入力は受け付けず、既知AAGUIDを固定snapshotの提供元名へ変換し、未知またはzero AAGUIDでは`browser`で登録User-AgentのOSを判定して初期名にします。OSも不明なら`Passkey`とし、同名を許可します。AAGUIDとUser-Agentは表示名専用であり、`attestation: none`を維持してセキュリティ判断には使いません。名称は登録後のeditでのみ変更できます。credential IDは全Userで一意、BEは登録後不変、`BE=0/BS=1`は全境界で拒否し、BS・sign count・last usedは認証成功時だけ更新します。全資格情報が`BS=0`のPasskey 1件だけなら、登録・ログイン成功後に追加資格情報へのwarningを1回表示します。

`additional_login_methods`へ`siwe`を選択した場合だけ`siwe-rb` 0.2.xと`:siweable`を追加します。`:siweable`はDeviseの公開module登録契約に従ってmodel、controller、routeを登録し、Warden strategyは追加しません。mapper拡張をroutes評価前に読み込み、成功時は紐付いた既存Userの`active_for_authentication?`を確認してDeviseの`sign_in`を呼びます。

`SiweIdentity`はUserごとに複数の名前付きEOA addressを保持します。signupは署名検証後にUserと最初のidentityをtransactionで作成し、loginは既存identityだけを受け付けます。loginで有効な署名を検証した後にidentityが見つからない場合、`POST /users/sign_in/siwe`は`401 { "error": "wallet_not_registered" }`を返し、画面は未登録であることと登録済みウォレットまたはアカウント作成の利用を案内します。署名不正、期限切れ、別session、無効なUserは登録状況を開示せず、汎用的な署名検証エラーを表示します。signupと追加登録ではEIP-6963 `ProviderInfo.name`をtrimし、1〜50文字なら初期名として保存します。欠落・不正・長すぎる名前と従来型`window.ethereum`は`Wallet`にし、同名を許可します。Provider情報は自己申告の表示情報としてのみ扱い、address・署名・認証器の信頼判定には使いません。名称変更はedit、解除は別資格情報による対象外再認証を行うshowへ分離します。SIWEで確立したsessionの認証元identityは一覧で「現在使用中」と表示し、解除導線を出さず、解除endpointでも拒否します。最後の資格情報にも解除導線を出しません。WebAuthn／SIWE challengeはpurpose、User、browser session、5分の期限、消費時刻、破壊操作では削除対象へbindingし、transaction内で一度だけ消費します。最後の資格情報、現在のsessionの認証元identity、対象自身による再認証、別User、期限切れ、replayを拒否します。RPC、ERC-1271、WalletConnect、外部SaaSは導入しません。
