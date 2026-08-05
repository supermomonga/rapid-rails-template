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
  --image-delivery=rails \
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

`--profile-features`は`screen_name`、`display_name`、`avatar`をカンマ区切りで指定します。既定では3機能すべてを選択し、`--profile-features=`と空値を指定するとProfile modelとプロフィール管理画面を生成しません。対話時はGumの複数選択を使用します。`screen_name`と`display_name`は選択時に必須かつ一意となり、User作成時にHaikunatorで自動生成されます。両方を選択した場合、`display_name`には自動生成した`screen_name`のCamelCaseを設定します。`avatar`を選択した場合、画像未設定時はUser IDから決定的に生成したBoring Avatarを表示し、設定済み画像はプロフィール編集画面から削除してBoring Avatarへ戻せます。生成seedを保存する追加columnは作りません。

DeviseによるユーザーID＋パスワード認証は全構成で必須です。`--additional-login-methods`は既存Userへ後付けできる追加ログイン方法をカンマ区切りで指定し、現在は`siwe`だけを選択できます。既定値および`--additional-login-methods=`は追加方式なしです。SIWEを選択しても会員登録はユーザーID＋パスワードで行い、ログイン後の「アカウント設定」内にある「EVMウォレットログイン」タブからEOA walletを追加します。登録名は`Wallet #<現在の登録数+1>`として自動設定され、編集画面で変更できます。解除は編集とは別画面で、現在のパスワードを確認して実行します。アプリ内の関連・認可・監査には`users.id`を使用し、`login_id`やwallet addressを内部識別子にしません。

`--image-delivery`は`rails`または`imgproxy`を指定し、既定値は`rails`です。Rails配信はActive Storageのnamed variant／representation route、imgproxy配信は署名済みURLを使用します。どちらもActive Storage DBを画像storageのsource of truthとし、実行時に相互fallbackしません。imgproxyではRailsとは別のserviceと環境変数が必要です。生成アプリの`docs/image_delivery.md`にnamed variant、upload制約、起動方法、production要件を記載します。

`--default-locale`は`ja`または`en`を指定し、既定値は`ja`です。生成アプリには両言語のlocaleを用意しますが、requestごとの切替UIやUserへのlocale保存は生成しません。productionのcanonical originは`APPLICATION_ORIGIN`環境変数で明示し、development/testだけが固定のローカル既定値を持ちます。

`--job-operations=enable`はSolid Queue使用時だけ選択でき、Mission Control Jobs 1.1.0を`/admin/jobs`へmountします。画面は既存の管理者認証、Action Policy、admin navigationへ統合し、Mission Control独自のHTTP Basic認証は使用しません。完了ジョブはSolid Queue 1.6.0の標準設定により1日保持した後、毎時12分に公式APIでbatch削除されます。失敗ジョブはcleanup対象外で、管理者がretryまたはdiscardするまで保持されます。

リポジトリの`mise run generate-sampleapp`はSIWE、PWA、Web Push、Solid Queue、管理者向け運用画面、全Profile機能、imgproxy、API、Solid Cable、mail、Dokployを有効にした全部入りの日本語sampleを生成します。既存の`sample/`は削除してから同じ場所へ再生成します。

`rake evidence:update`（`mise run evidence-update`）は同じ全部入り日本語sampleを1回だけ生成し、password基底の共通画面、SIWE、imgproxyを含む全シナリオをCapybaraとPlaywright Chromiumで一括撮影します。成果物は`docs/evidence/full-ja`へ保存され、生成、全Rails test、RuboCop、撮影、整合性検証が完了するまで既存エビデンスは置換しません。

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
