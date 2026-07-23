# コントリビューションガイド

Rapid Rails Templateへのコントリビューションを歓迎します。

## 開発環境

開発対象はRails 8.1.xおよびRuby 4.0.xです。リポジトリで使用するRubyは`mise.toml`でRuby 4.0.6へ固定しています。

```console
mise install
gem install gum -v 0.3.2
bin/build-bootstrap
bin/verify-bootstrap
ruby -Itest -e 'Dir["test/{unit,integration}/**/*_test.rb"].sort.each { |file| require_relative file }'
```

`.ruby-version`は追加せず、Rubyバージョンは`mise.toml`だけで管理します。

## 変更の進め方

1. 変更の目的と影響範囲を明確にする。
2. 振る舞いまたは設計を変更する場合は、関連する設計文書を先に更新する。
3. 実装開始後は、分割ソースと単体テストを変更する。
4. 生成コマンドでルートの`bootstrap.rb`を再生成する。
5. 生成物の同期検証と、Railsアプリケーションを生成する統合テストを実行する。
6. テンプレートの内容fingerprintが変わった場合は`rake evidence:update`でDevise／SIWEのUIエビデンスを更新する。

`rake evidence:verify`はChromiumを起動せずに保存済みエビデンスの鮮度と整合性を検証します。通常のMinitestにも同じ検証が含まれます。スクリーンショット更新は一時ディレクトリで両認証方式が成功してから`docs/evidence/`へ反映されるため、途中失敗時は既存成果物を維持します。

## 生成物の扱い

ルートの`bootstrap.rb`は、`src/rapid_rails_template/`以下のソースから決定的に生成する成果物です。前段ランチャーとApplication Template payloadの両方を内包します。

- `bootstrap.rb`を直接編集しない。
- 分割ソースと異なる生成物をコミットしない。
- 生成手順を経ずに配布用ファイルだけを修正しない。

## ファイル編集手段の優先順位

テンプレートが生成先アプリケーションを変更するときは、次の順序で手段を選びます。

1. Rails Generator/Application Template APIおよび`Thor::Actions`
2. 対象ライブラリが提供する設定APIやgenerator
3. YAMLなど、対象形式に対応した構造化データ操作
4. PrismによるRuby AST解析とノード位置に基づく編集

安全な構造化手段が存在しない場合は、処理を明示的に失敗させます。単純なgrep、曖昧な文字列置換、暗黙のフォールバックは追加しません。

## 互換性

対応範囲はRails `>= 8.1, < 8.2`、Ruby `>= 4.0, < 4.1`です。対象外のバージョンを支える条件分岐や互換レイヤーは追加しません。

## 文書変更の確認

- Markdown内の相対リンクが存在すること。
- `README.md`と設計文書で対応バージョンが一致すること。
- Mermaidフローチャートの構文が正しく、意図した順序で表示されること。
- `git diff --check`で空白エラーがないこと。
