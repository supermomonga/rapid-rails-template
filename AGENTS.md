# Repository Guidelines

## プロジェクト構成とモジュール配置

このリポジトリは現在、設計段階です。ルートにはプロジェクト全体の文書（`README.md`、`CONTRIBUTING.md`）と環境設定（`mise.toml`）があります。詳細な設計判断は `docs/` に置きます。`architecture.md` はコンポーネント境界、`options.md` は質問項目の振る舞い、`stack.md` は採用技術、`template-flow.md` は実行順序の正本です。

実装時には `src/rapid_rails_template/`、実行用スクリプトを置く `bin/`、Minitest の `test/unit/` と `test/integration/` を追加します。空のプレースホルダーディレクトリは作成しません。将来ルートへ追加する `bootstrap.rb` は生成物です。直接編集せず、分割ソースを変更して再生成してください。

## ビルド、テスト、開発コマンド

- `mise install`: 固定された Ruby 4.0.6 をインストールします。`.ruby-version` は追加せず、`mise.toml` を正本とします。
- `ruby --version`: 開発環境が Ruby 4.0.x であることを確認します。
- `git diff --check`: コミット前に空白エラーを検出します。

現時点では、実行可能なテンプレート、ビルドスクリプト、テストランナーはありません。実装後はリポジトリが提供する `bin/build-bootstrap` と `bin/verify-bootstrap` を使用し、正確な Minitest コマンドをこの文書と `CONTRIBUTING.md` に追記してください。

## コーディングスタイルと命名規則

Ruby は2スペースでインデントします。ファイル、メソッド、オプション識別子には `snake_case`、クラスとモジュールには `CamelCase` を使用します。`docs/architecture.md` の責務境界を守り、質問間の依存関係は非巡回にしてください。RuboCop 設定は計画中ですが、まだ存在しません。設定とコマンドが追加されるまで lint 成功を主張しないでください。

変更手段は、Rails Generator/Application Template API、ライブラリの generator、構造化データ操作、Prism による AST 編集の順で選びます。grep ベースの書き換え、曖昧な文字列置換、暗黙のフォールバック、Rails 8.1.x／Ruby 4.0.x の対象範囲外に対する互換処理は追加しません。

## テスト方針

Minitest を使用します。単体テストは `test/unit/`、アプリケーション生成の結合テストは `test/integration/` に配置し、ファイル名は `_test.rb` で終わらせます。`bootstrap.rb` の決定的生成、分割ソースとの同期、キャンセル時の無副作用、選択肢の正規化、実行順序、後始末、空白やシェルメタ文字を含むパスを検証してください。

## コミットとプルリクエスト

現在の履歴では、`docs: define rapid rails template architecture` のような簡潔な Conventional Commits 形式を使用しています。`docs:`、`feat:`、`fix:`、`test:` に命令形の要約を続けてください。

プルリクエストには、問題、構造的な解決方法、影響する選択肢やフェーズ、実施した検証を記載します。関連 Issue をリンクし、振る舞いの実装より先に設計文書を更新してください。分割ソースを変更した場合のみ、同期検証を通過した再生成済み `bootstrap.rb` を含めます。
