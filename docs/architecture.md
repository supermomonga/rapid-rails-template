# アーキテクチャ

## 目的

Rapid Rails Templateは、Rails 8.1アプリケーションで繰り返し行う初期設定を、安全かつ再現可能に適用するApplication Templateを提供します。利用者との対話、実行計画、個別処理、ファイル編集を分離し、Railsのバージョン変更に追従しやすい構造を採用します。

この文書に示す`bootstrap.rb`、`src/`、`bin/`、`test/`を実装し、空ディレクトリやプレースホルダーは置きません。

## 対応範囲

| 対象 | 対応範囲 |
| --- | --- |
| Rails | `>= 8.1, < 8.2` |
| Ruby | `>= 4.0, < 4.1` |

Rails 8.0以前、Rails 8.2以降、Ruby 3.x、Ruby 4.1以降を対象とした互換処理は持ちません。

## 構成

```text
bootstrap.rb                        # URL配布する生成済み単一ファイル
src/rapid_rails_template/
├── entrypoint.rb                   # rails newより前のセットアップ入口
├── generator_options.rb            # 回答からrails new optionを構築
├── rails_template.rb               # Application Template contextへの入口
├── questionnaire.rb               # 全質問の収集
├── configuration.rb               # 回答の正規化・不変化
├── execution_plan.rb              # 実行予定と順序
├── runner.rb                       # 確認後の処理制御
├── steps/                          # pre_bundle/post_bundle/verify処理
└── editors/                        # Prism等による対象別構造化編集
bin/
├── build-bootstrap                 # bootstrap.rbの決定的生成
├── verify-bootstrap                # 生成物と分割ソースの同期確認
├── update-evidence                 # 共通・SIWE差分・画像配信差分の生成・撮影・成果物置換
└── verify-evidence                 # エビデンスの鮮度と整合性確認
test/
├── unit/
└── integration/
docs/evidence/
├── devise/
└── siwe/
```

## 配布モデル

公開入口はルートの`bootstrap.rb`です。保守対象の正本は`src/rapid_rails_template/`以下に置き、前段ランチャーとApplication Template payloadを含む単一ファイルを決定的に生成してコミットします。`bootstrap.rb`を直接編集する運用は認めません。

利用者はリリースされた`bootstrap.rb`をローカルへ取得し、生成先パスを引数としてRubyで実行します。可変なbranchではなく、release tagまたはcommitへ固定されたURLを正式な配布URLとします。

```console
gem install gum -v 0.3.2
curl -fsSL BOOTSTRAP_URL -o /tmp/rapid-rails-bootstrap.rb
ruby /tmp/rapid-rails-bootstrap.rb --app-id=APP_ID --app-name="My App" APP_PATH
```

`--app-id`を省略した場合は`APP_PATH`のbasenameを初期値としてRailsアプリIDを質問し、Rails標準の`--name`へ変換します。`--app-name`を省略した場合は確定済みのRailsアプリIDを初期値として表示用アプリ名を質問します。表示用アプリ名はRails generatorへ渡さず、生成アプリのApplication Identityへ保存します。

Application Templateを`rails new APP_PATH -m TEMPLATE_URL`で直接指定すると、Rails標準ファイルの生成後まで質問を開始できません。新たな要件には、次のように`rails new`開始前に確定しなければならない項目があります。

- `--css=tailwind`
- `--skip-rubocop`
- `--skip-action-mailer`と`--skip-action-mailbox`
- Rails標準Docker/Kamalを常時生成するため、これらをskipするoptionは渡さない
- Kamalは`production`・`staging` destinationを必須とし、LitestreamのCloudflare R2 bucket、最小権限のaccount-owned API token、1Password vault内の資格情報、volume、restore markerをdestination単位で分離する
- Rails標準のSolid Queue/Cableを条件付きにするためのSolid系オプション

これらを生成後のファイル削除で代替しません。`bootstrap.rb`が対話と実行確認を`rails new`より前に行い、確定したgenerator optionでRailsを起動してからApplication Template処理へ引き継ぎます。

## 質問・確認・実行の境界

ランチャーは次の3フェーズを混在させません。

1. 質問: 依存順に、現在の回答で適用可能な質問へすべて回答させる。
2. 確認: 回答を正規化・検証し、派生値と実行計画を一覧表示して最終承認を求める。
3. 実行: 承認済みの設定と計画を不変化し、追加質問なしで`rails new`とApplication Templateを実行する。

「すべての質問」は、依存条件を満たす適用可能な質問をすべて意味します。たとえばPWAを使わない場合はWeb Pushを質問せず、仕様で定めた`skip`へ正規化します。質問を省略した結果を暗黙に推測せず、必ず明示的な正規化規則を持たせます。

質問中に実行する外部commandは対話UIを提供するGum実行可能ファイルだけです。生成先directory、一時ファイル、Gemfile、設定ファイルは作成・変更せず、generatorや設定commandも実行しません。回答が別の質問に影響しても、その場でstepを実行せず、後続質問の表示条件だけを評価します。

全質問の完了後に、`Auto`値、条件により省略した値、選択肢間の制約を解決します。確認画面には、少なくとも次を表示します。

- 各質問の回答と正規化後の実効値
- Railsのアプリケーション名
- `Auto`や条件付き`skip`を解決した理由
- `rails new`へ渡すgenerator option
- 追加・除外するGem
- 実行するgenerator、設定step、検証step
- 生成するdeployment fileとproduction process

利用者が承認しなければ、アプリケーションも一時ファイルも生成せず終了します。承認後は設定と実行計画を変更せず、追加の対話が必要になった場合は仕様漏れとして失敗させます。

## ランチャーからApplication Templateへの引き継ぎ

`bootstrap.rb`はRuby標準ライブラリと、対話UI用に事前導入された`gum` 0.3.2で起動します。Rails 8.1.x、Ruby 4.0.x、gum 0.3.2、gum gemに同梱された現在のplatform向けGum実行可能ファイルを質問開始前に検証します。gumを自動installしたり、標準入力を直接読む代替UIへ切り替えたりしません。Rails executableはRubyGemsから解決し、shell文字列ではなく引数配列で子プロセスを起動します。

確認後は、次の一時ファイルを作成します。

- `rails_template.rb`: `bootstrap.rb`に内包されたApplication Template payload
- `configuration.json`: 正規化済みの回答と実行計画に必要な値

一時ファイルは所有者だけが読み書きできる権限で作成します。`configuration.json`のパスは`RAPID_RAILS_TEMPLATE_CONFIG`環境変数で子プロセスへ渡し、`rails new`には`--template`で`rails_template.rb`を渡します。Application Templateは設定を再質問せず、受け取った値を検証してからstepを登録します。

子プロセスの標準出力・標準エラーは利用者へ逐次表示し、終了statusをそのまま成否判定に使います。成功・失敗・割り込みのいずれでも一時ファイルを削除します。子プロセス起動失敗を別コマンドへフォールバックしません。

## コンポーネントの責務

### `entrypoint`

`bootstrap.rb`の生成先パス、RailsアプリID、表示用アプリ名、個別設定引数を検証し、環境検証から`runner`の起動までを行います。個別設定引数は質問への事前回答として扱い、Railsへ渡す任意の`rails new`引数は受け付けません。

### `generator_options`

RailsアプリID、表示用アプリ名、固定構成、正規化済み回答から、順序付きの`rails new`引数配列とApplication Identity payloadを構築します。RailsアプリIDだけを`--name`へ変換し、shell展開される文字列は生成せず、確認画面へ同じ内容を表示します。

### `rails_template`

Application Template contextで`configuration.json`を読み込み、schemaと値を再検証します。`gem`、`after_bundle`、`generate`、`rails_command`などのRails Generator APIを使うstepを登録し、対話処理は行いません。

### `questionnaire`

CLI引数の事前回答を受け取り、`rails new`を起動する前に未指定のRailsアプリIDと表示用アプリ名を`Gum.input`、未回答の適用可能な項目を`Gum.choose`で依存順に収集します。RailsアプリIDには生成先のbasename、表示用アプリ名には確定済みのRailsアプリIDを初期値として表示し、各選択質問は既定値を選択済みとして表示します。実行計画の最終承認には`Gum.confirm`を使用します。表示条件だけを評価し、正規化、実行計画の構築、step実行は行いません。

### `configuration`

全質問の完了後に回答を検証・正規化し、`Auto`と非適用値を解決します。未回答、無効値、矛盾する組み合わせを確認画面より前に拒否し、承認後は変更されない設定として保持します。

### `execution_plan`

正規化済み設定から実行対象のstepと順序を確定し、回答、実効値、generator option、Gem、生成物、production processを含む確認表示を構築します。承認後に内容が変化することはありません。

### `runner`

利用者の最終確認後に限り、確定したgenerator optionで`rails new`を起動し、続く実行計画をフェーズ順に処理します。確認前のアプリケーション生成、step実行、失敗したstepを別手段で暗黙に継続する処理は持ちません。

### `steps`

機能ごとの変更を、次のフェーズに分類します。

- `pre_bundle`: `gem`など、bundle installより前に必要な宣言
- `post_bundle`: インストール済みgemのgenerator、`rails_command`、設定処理
- `verify`: 生成結果と設定の検証

各stepは必要な選択結果を明示し、他のstepの内部状態へ依存しません。

### UIエビデンス

生成アプリケーションにはtest環境専用の`evidence:capture` Rake taskを配置します。taskは撮影前にtest databaseを再構築し、Capybaraで実ページを操作してPlaywright Chromiumでfull-page PNGと撮影レポートを出力します。撮影の成否にかかわらずtest databaseを再度初期化するため、証跡用データは通常のfixture testへ残りません。共通画面は実際のDevise login form、SIWE画面はdatabase challengeと署名検証を通して同じUserへ認証し、テスト専用login routeや認証fallbackは追加しません。

リポジトリ側の`rake evidence:update`は選択可能な機能をすべて有効にした日本語sampleを1回だけ生成し、全Rails test、RuboCop、Thruster cache smoke、共通・SIWE・avatar画面の撮影が成功してからmanifest、Markdown索引、画像hashを確定して`docs/evidence/`を置換します。同じcapture IDとviewportの重複を拒否し、鮮度はcommit hashではなく、テンプレート分割ソースと撮影オーケストレーターの内容fingerprintで判定します。

### アプリ内通知

`rails_template`は常設Profileの設定後・既定View生成前に`configure_in_app_notifications`を常に登録します。この機能はConfigurationとQuestionnaireへ選択肢を追加しません。`Notification`がAction Textのリッチテキスト本文、公開条件、通知先を持ち、`NotificationDelivery`は個別通知の受信者と既読状態だけを担当します。個別受信者の同期serviceは通知保存transaction内で差分同期し、継続する配信の既読状態を保持します。全体通知はUser別の配信行を作らず、Userの`global_notifications_read_at`を最終確認位置として直接`Notification`から取得するため、通知後に登録したUserにも表示できます。公開HTTP controllerは個別配信と全体通知を「あなたへの通知」と「お知らせ」に分け、「お知らせ」を実際に表示した時だけ専用の更新endpointで最終確認位置を単調に進めます。管理フォームは固定ページ編集と同じLexxy editorを使用し、個別受信者はProfileの`display_name`だけで検索・表示します。管理CRUDと受信者検索は`NotificationPolicy`でadminへ限定します。Web Pushは`WebPushSettingsController`と`/web-push`へ分離し、アプリ内通知のmodel、配信行、routeを利用しません。

### `editors`

対象ファイルごとの構造化編集を担当します。汎用的なgrep・置換ヘルパーは作りません。Rubyコードを編集するeditorはPrismでASTを解析し、期待する構造とノード位置を確認してから変更します。期待する構造が見つからない場合は失敗として報告します。

## 変更手段の選択

生成先アプリケーションの変更には、次の優先順位を適用します。

1. Rails Generator/Application Template APIおよび`Thor::Actions`
2. 対象ライブラリが提供する設定APIやgenerator
3. 対象形式に対応した構造化データ操作
4. PrismによるRuby AST解析とノード位置に基づく編集

安全な構造化手段がない場合は、その処理を実装せず明示的に失敗させます。単純なgrep、曖昧な文字列置換、暗黙のフォールバックは採用しません。

## 依存方向

`entrypoint`は`configuration`、`questionnaire`、`generator_options`、`execution_plan`、`runner`を組み立てます。Profileは設定や質問へ含めず、`execution_plan`と`rails_template`が全構成へ`screen_name`、`display_name`、`avatar`を登録します。`runner`は確定済みのgenerator optionとApplication Template payloadだけを子プロセスへ渡します。`rails_template`は確定済み設定から`steps`を登録し、`steps`は必要に応じて対象別の`editors`を利用します。下位コンポーネントから対話処理や`entrypoint`へ依存させません。

固定技術スタック、条件付き機能、デプロイ要件は[採用技術とセットアップ要件](stack.md)を正本とします。対話項目と依存関係は[対話オプションの定義方針](options.md)を正本とします。

## 検証要件

- 最終確認で中止した場合、生成先ディレクトリも一時ファイルも作成されないこと。
- 同じ分割ソースから同一内容の`bootstrap.rb`を再生成できること。
- `bootstrap.rb`と分割ソースの不一致を検出できること。
- 空白やshell metacharacterを含む生成先パスが、shell展開されず単一引数として渡されること。
- 空白やshell metacharacterを含む表示用アプリ名がshell展開されずJSON payloadの単一値となり、RailsアプリIDだけが`--name`の単一引数として渡されること。
- Application Templateへ渡した設定が質問時の正規化済み設定と一致すること。
- 質問中と確認待ちの状態では、生成先directory、一時ファイル、外部commandの副作用がないこと。
- すべての適用可能な質問が一度だけ行われ、非適用の質問には仕様どおりの明示値が設定されること。
- 確認表示が回答、実効値、generator option、Gem、step、生成物を正しく表すこと。
- 承認後に追加質問が行われず、設定と実行計画が変化しないこと。
- 成功、失敗、割り込みのすべてで一時ファイルが削除されること。
- Rails 8.1.x／Ruby 4.0.xで一時アプリケーションを生成できること。
- gum 0.3.2と現在のplatform向けGum実行可能ファイルがない場合、質問開始前に失敗すること。
- RailsアプリIDと表示用アプリ名の入力、対話的な選択、最終確認が`Gum.input`、`Gum.choose`、`Gum.confirm`を通り、キャンセル時に生成を開始しないこと。
- 生成後にpending migrationが残らず、追加の手作業なしでRails testを起動できること。
- 生成済みschema annotationがAnnotateRbの公式既定と一致し、通常のRails testが`--frozen`で更新忘れを非破壊検出すること。
- SorbetとTapiocaが全構成へ常設され、Maintenance Taskと`db/seeds.rb`を含むapplication codeが`typed: true`以上、純粋なserviceが`typed: strict`となり、通常のRails testが型エラー、未解決定数、Gem／Rails DSL RBIの更新忘れ、重複shimを非破壊検出すること。
- 各選択肢について、選択したstepだけが順序どおり実行されること。

Application Templateが評価される時点では`rails new`による標準ファイル生成が進んでいます。そのため、本プロジェクトは最終確認をApplication Templateの内側へ置かず、`rails new`の前段へ置きます。
