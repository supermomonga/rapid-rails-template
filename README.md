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
ruby /tmp/rapid-rails-bootstrap.rb APP_PATH
```

`bootstrap.rb`は、gum 0.3.2と同梱されたGum実行可能ファイルを質問開始前に検証します。生成先を変更する前に`Gum.choose`による質問・回答検証・`Gum.confirm`による実行予定の確認を完了し、回答から`rails new`オプションを構築します。その後、内包するApplication Templateを一時ファイルへ展開して`rails new`を起動します。

各選択はCLI引数で個別に指定できます。指定済みの項目は再質問せず、未指定の適用可能な項目だけを質問します。すべての適用可能な項目を指定すると、質問と最終確認を行わず実行します。

```console
ruby /tmp/rapid-rails-bootstrap.rb \
  --pwa=skip \
  --web-push=skip \
  --active-job=skip \
  --solid-cache=use \
  --account-authentication=devise \
  --profile-features=screen_name,display_name,avatar \
  --api=enable \
  --action-cable=skip \
  --mail=auto \
  --action-text=use \
  --deployment=dokploy \
  APP_PATH
mise run generate-sampleapp
mise run generate-sampleapp-wallet-siwe
```

`--profile-features`は`screen_name`、`display_name`、`avatar`をカンマ区切りで指定します。既定では3機能すべてを選択し、`--profile-features=`と空値を指定するとProfile modelとプロフィール管理画面を生成しません。対話時はGumの複数選択を使用します。

リポジトリの`mise run generate-sampleapp`はDevise認証、`mise run generate-sampleapp-wallet-siwe`はWallet SIWE認証を指定します。どちらも既存の`sample/`を削除してから、同じ場所へアプリを再生成します。

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
