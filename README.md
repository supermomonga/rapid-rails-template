# Rapid Rails Template

Rapid Rails Templateは、Railsアプリケーションの初期設定を対話的かつ再現可能な形で自動化するためのApplication Templateプロジェクトです。毎回導入するRubyGemsや設定を、Railsが提供するGenerator APIを中心に適用します。

実行可能な`bootstrap.rb`は分割ソースから決定的に生成され、質問、実行計画の確認、`rails new`、Application Template適用を一つのコマンドで行います。

## 対応環境

| 対象 | 対応範囲 |
| --- | --- |
| Rails | `>= 8.1, < 8.2` |
| Ruby | `>= 4.0, < 4.1` |
| Gum for Ruby | `gum` 0.3.2 |
| Node.js / npm | daisyUIのinstallとTailwind CSS asset buildで使用する |

上記以外のバージョンに対する後方互換・前方互換処理は追加しません。開発環境ではRuby 4.0.6を使用します。

## 利用方法

リリースされた単一の`bootstrap.rb`を取得し、生成先のパスを引数として実行します。

```console
gem install gum -v 0.3.2
curl -fsSL BOOTSTRAP_URL -o /tmp/rapid-rails-bootstrap.rb
ruby /tmp/rapid-rails-bootstrap.rb --app-id=APP_ID --app-name="My App" APP_PATH
```

`--app-id=APP_ID`はRails内部識別子を生成先`APP_PATH`とは独立して指定し、Rails標準の`--name`へ変換します。省略した場合は、`APP_PATH`のbasenameを初期値として`Gum.input`で質問します。`--app-name=NAME`はheader、title、PWA、OGP、メール、通知などの表示用アプリ名です。省略した場合は確定済みのRailsアプリIDを初期値として質問します。旧`--name`は受け付けません。

`bootstrap.rb`は、gum 0.3.2と同梱されたGum実行可能ファイルを質問開始前に検証します。生成先を変更する前に`Gum.input`と`Gum.choose`による質問・回答検証、`Gum.confirm`による実行予定の確認を完了し、回答から`rails new`オプションを構築します。その後、内包するApplication Templateを一時ファイルへ展開して`rails new`を起動します。

RailsアプリID、表示用アプリ名、各選択はCLI引数で個別に指定できます。指定済みの項目は再質問せず、未指定の適用可能な項目だけを質問します。すべての適用可能な項目を指定すると、質問と最終確認を行わず実行します。

```console
ruby /tmp/rapid-rails-bootstrap.rb \
  --app-id=my_app \
  --app-name="My App" \
  --pwa=skip \
  --web-push=skip \
  --active-job=skip \
  --job-operations=disable \
  --maintenance-tasks=disable \
  --solid-cache=use \
  --additional-login-methods=siwe \
  --profile-features=screen_name,display_name,avatar \
  --api=enable \
  --action-cable=skip \
  --mail=auto \
  --deployment=dokploy \
  --default-locale=ja \
  APP_PATH
mise run generate-sampleapp
mise run evidence-update
mise run evidence-verify
```

`--profile-features`は`screen_name`、`display_name`、`avatar`をカンマ区切りで指定します。既定では3機能すべてを選択し、`--profile-features=`と空値を指定するとProfile modelとプロフィール管理画面を生成しません。対話時はGumの複数選択を使用します。`screen_name`と`display_name`は選択時に必須かつ一意となり、User作成時にHaikunatorで自動生成されます。両方を選択した場合、`display_name`には自動生成した`screen_name`のCamelCaseを設定します。`avatar`を選択した場合、Cropper.js 2.1.1と汎用`image_crop` Stimulus controllerを生成し、プロフィールViewから1:1と512×512を設定してupload前にcropします。controllerはアスペクト比未指定の自由crop、任意比率、任意の出力幅・高さにも再利用でき、avatarのサーバー側policyは正方形を必須にします。画像未設定時はUser IDから決定的に生成したBoring Avatarを表示し、設定済み画像はプロフィール編集画面から削除してBoring Avatarへ戻せます。生成seedを保存する追加columnは作りません。

Passkeyによるパスワードレス認証は全構成で必須です。登録・ログインはいずれもユーザーIDを入力しないdiscoverable credential方式で、複数のPasskeyを登録できます。`--additional-login-methods`は追加方式をカンマ区切りで指定し、現在は`siwe`だけを選択できます。SIWE選択時は新規登録と既存Userへのログインを別ceremonyとして提供し、複数のEOA walletを登録できます。未知のwalletによるログインからUserを暗黙作成しません。Passkey・wallet・アカウントの削除は操作ごとのchallengeと別資格情報による再認証を要求し、最後のログイン手段は削除できません。全認証資格情報が未バックアップのPasskey 1件だけなら、ログイン後にPasskey一覧へ進む「ログイン方法を追加」リンク付きのwarningを表示します。アプリ内の関連・認可・監査には`users.id`を使用し、credential IDやwallet addressを内部識別子にしません。

画像は全環境でActive Storage DBの専用SQLite databaseへ保存し、libvipsでvariantを生成します。画像URLはActive Storage公式のproxy routeへ解決し、productionではThrusterのHTTP cacheがwarmなrequestをPuma、Rails、SQLiteへ転送せず返します。生成アプリの`docs/image_delivery.md`にnamed variant、公開signed URL、cache制約を記載します。

`--default-locale`は`ja`または`en`を指定し、既定値は`ja`です。生成アプリには両言語のlocaleを用意しますが、requestごとの切替UIやUserへのlocale保存は生成しません。productionのcanonical originは`APPLICATION_ORIGIN`環境変数で明示し、development/testだけが固定のローカル既定値を持ちます。

`--job-operations=enable`はSolid Queue使用時だけ選択でき、Mission Control Jobs 1.1.0を`/admin/jobs`へmountします。画面は既存の管理者認証、Action Policy、admin navigationへ統合し、Mission Control独自のHTTP Basic認証は使用しません。完了ジョブはSolid Queue 1.6.0の標準設定により1日保持した後、毎時12分に公式APIでbatch削除されます。失敗ジョブはcleanup対象外で、管理者がretryまたはdiscardするまで保持されます。

生成アプリケーションにはSorbetとTapiocaを常設し、`sorbet/config`、Gem RBI、Rails DSL RBI、`bin/tapioca`を生成します。controller、concern、helper、model、policy、service、job、mailer、validator、application-owned `lib`、config、test、`db/seeds.rb`は生成時から`# typed: true`以上とし、設定・通知・画像検証などの純粋なserviceは`# typed: strict`にします。application codeには`T.untyped`を残さず、Action Viewのroute helper module、capture block、form builderも公開契約へ型付けします。migration、schemaはSorbet既定の`typed: false`に留めます。

`sorbet/rbi/dsl`、`sorbet/rbi/gems`、`sorbet/rbi/annotations`は生成物であり、手動編集しません。Rails DSL由来の型は`RAILS_ENV=test bin/tapioca dsl --environment=test`、Gem APIは`bin/tapioca gems`で更新し、アプリがRubyで定義するmethodは同じ`.rb`へinline `sig`を記述します。Tapiocaが表現できないframework wiringは`sorbet/rbi/shims/framework_bindings.rbi`、Boring AvatarsのGem RBIで不足する型aliasは`sorbet/rbi/shims/boring_avatars.rbi`、FFIまたはHTTPXのGem RBIから参照されるBundler同梱APIは`sorbet/rbi/shims/bundler_connection_pool.rbi`で補います。`sorbet/rbi/todo.rbi`は残さず、通常の`bin/rails test`がRBIの鮮度、shimの重複、`bundle exec srb tc`を検証するため、`bin/ci`とGitHub Actionsでも同じ契約が適用されます。

リポジトリの`mise run generate-sampleapp`はSIWE、PWA、Web Push、Solid Queue、管理者向け運用画面、全Profile機能、API、Solid Cable、mail、Dokployを有効にした全部入りの日本語sampleを生成します。既存の`sample/`は削除してから同じ場所へ再生成します。

生成後はsample専用のArticle scaffoldを`/articles`へ追加し、`sample_user_01`から`sample_user_10`までのscreen nameを持つ10ユーザーと、各ユーザー50件（公開40件、draft 10件）、合計500件の記事をseedします。各Userにはsample表示用のPasskey credentialを1件作成しますが、秘密鍵は保存しないため、そのcredentialを使った実ログインはできません。公開済み記事は誰でも閲覧でき、認証済みUserは自分のdraftを含む記事の作成・閲覧・編集・削除ができます。このArticleはscaffold templateの確認用であり、配布用`bootstrap.rb`や`rake evidence:update`の生成アプリには含めません。

`rake evidence:update`（`mise run evidence-update`）は同じ全部入り日本語sampleを1回だけ生成し、Passkey登録・紛失リスク警告・複数Passkey管理・削除時再認証、SIWE、avatarを含む全シナリオをCapybaraとPlaywright Chromiumで一括撮影します。さらに実際のThrusterを非特権portで起動し、Active Storage variantがcache miss後の再requestでhitすることを検証します。成果物は`docs/evidence/full-ja`へ保存され、生成、全Rails test、Sorbet・RBI検証、RuboCop、撮影、整合性検証が完了するまで既存エビデンスは置換しません。

`rake evidence:verify`（`mise run evidence-verify`）はブラウザを起動せず、生成元fingerprint、manifest、README、PNGの欠落・余剰・SHA-256・寸法を検証します。通常のリポジトリMinitestにも同じ検証を含むため、テンプレート変更後にエビデンスを更新し忘れるとテストが失敗します。MD内のbase commitは追跡情報であり、鮮度判定には未コミット変更も反映できる内容fingerprintを使用します。

`bootstrap.rb`は分割されたソースから生成する配布成果物とし、直接編集は行いません。リリースされたcommitまたはtagへ固定されたURLを使用し、可変な内容へ暗黙に切り替えません。

## 設計原則

- 依存順にすべての適用可能な質問へ回答し、実効値と全実行予定を確認してから`rails new`を開始する。
- 最終承認後は追加質問を行わず、不変化した設定と実行計画を処理する。
- Rails Generator/Application Template APIや対象ライブラリのAPIを優先する。
- Rubyコードを編集する必要がある場合は、PrismによるAST解析を利用する。
- 単純なgrep、曖昧な文字列置換、暗黙のフォールバックは採用しない。
- RailsまたはRubyの対象範囲外を互換処理で吸収しない。

## ドキュメント

- [アーキテクチャ](docs/architecture.md)
- [採用技術とセットアップ要件](docs/stack.md)
- [テンプレート処理フロー](docs/template-flow.md)
- [対話オプションの定義方針](docs/options.md)
- [コントリビューションガイド](CONTRIBUTING.md)

## ライセンス

[MIT License](LICENSE)
