# Repository Guidelines

## プロジェクト構成とモジュール配置

ルートにはプロジェクト全体の文書（`README.md`、`CONTRIBUTING.md`）と環境設定（`mise.toml`）があります。詳細な設計判断は `docs/` に置きます。`architecture.md` はコンポーネント境界、`options.md` は質問項目の振る舞い、`stack.md` は採用技術、`template-flow.md` は実行順序の正本です。

実装は `src/rapid_rails_template/`、実行用スクリプトは `bin/`、Minitestは `test/unit/` と `test/integration/` に置きます。空のプレースホルダーディレクトリは作成しません。ルートの `bootstrap.rb` は生成物です。直接編集せず、分割ソースを変更して再生成してください。

## ビルド、テスト、開発コマンド

- `mise install`: 固定された Ruby 4.0.6 をインストールします。`.ruby-version` は追加せず、`mise.toml` を正本とします。
- `gem install gum -v 0.3.2`: `bootstrap.rb`の対話UIとテストで使用する固定versionのgum gemをインストールします。
- `ruby --version`: 開発環境が Ruby 4.0.x であることを確認します。
- `git diff --check`: コミット前に空白エラーを検出します。

- `bin/build-bootstrap`: 分割ソースから`bootstrap.rb`を生成します。
- `bin/verify-bootstrap`: `bootstrap.rb`と分割ソースの同期を検証します。
- `ruby -Itest -e 'Dir["test/{unit,integration}/**/*_test.rb"].sort.each { |file| require_relative file }'`: Minitestを実行します。

## コーディングスタイルと命名規則

Ruby は2スペースでインデントします。ファイル、メソッド、オプション識別子には `snake_case`、クラスとモジュールには `CamelCase` を使用します。`docs/architecture.md` の責務境界を守り、質問間の依存関係は非巡回にしてください。生成先では構造化補正済み`.rubocop.yml`と`bin/rubocop -a`を使用します。

変更手段は、Rails Generator/Application Template API、ライブラリの generator、構造化データ操作、Prism による AST 編集の順で選びます。grep ベースの書き換え、曖昧な文字列置換、暗黙のフォールバック、Rails 8.1.x／Ruby 4.0.x の対象範囲外に対する互換処理は追加しません。

## オプション選択UI

`bootstrap.rb`の対話的な選択肢と最終確認には、`marcoroth/gum-ruby`が提供する`Gum.choose`と`Gum.confirm`を使用してください。標準入力を直接読み取る独自の選択UIや、gumが利用できない場合の代替UIは追加しません。対応するgum gemのversionと実行可能ファイルを質問開始前に検証し、利用できない場合は明示的に失敗させてください。

## View実装と目視検証

- Viewを実装するときは、意図に合うdaisyUI component、part、modifierが存在するかを先に確認し、存在する場合はそれらを使用してください。daisyUI componentで表現できるUIをTailwind CSS utilityだけで再実装しません。
- daisyUI componentの内部寸法とpaddingは既定値を優先し、`menu` itemなどへ`min-h-*`や`p-*`を追加しません。サイズ変更が必要な場合はTailwind CSS utilityより先にdaisyUIの公式size modifierまたはtheme tokenを使用し、既定値を上書きする理由を`docs/`とテストへ残してください。
- ページ全体に作用する追加・絞り込み・一括操作は、Viewで`content_for :page_actions_primary`または`content_for :page_actions_secondary`へ設定し、任意の場所へ直接配置しません。基本操作はprimary、絞り込みやapplication/server選択などの補助操作はsecondaryを使用します。個別model・table row・formに属する編集、削除、pause、run、保存、戻る操作は対象のcard、row、form内に残します。
- page actionsは共通layout/helperが、640px未満ではsecondaryからprimaryの順に1列、640px以上では左secondary・右primaryの2列で配置します。タブなしではページ名直下の`card-rapid`内、tabpanelを伴うタブではactiveな`tab-content`内の上部へcardを重ねず配置し、View側で同じresponsive layoutやcard shellを再構築しません。
- 標準card surfaceは`card-rapid`を使用します。これは`card card-border border-base-300 bg-base-100 shadow-none`をTailwind CSSの`@apply`で集約した生成アプリ共通classです。error borderなど異なるvariantへ安易に適用せず、そのvariantのdaisyUI classを維持してください。
- タブ付きコンテンツは生成アプリの`ApplicationHelper#with_tab`を使用し、Viewやlayoutで`tab`と`tab-content`を直接組み立てません。active判定は各tabの`path`によるprefix判定、またはoptionalな`is_active` lambdaで指定し、block本文はhelperがactive tab直後へ配置します。横スクロール用の`overflow-x-auto`、1段表示用の`min-w-max`、tabpanel用の`sticky`もhelperが一括して生成し、個別Viewでは重複させません。tabpanelを伴わないtab形式selectorは対象外です。
- native dialogを使うdaisyUI modalは生成アプリの`ApplicationHelper#with_modal`を使用し、Viewやlayoutで`modal`、`modal-box`、`modal-action`、`modal-backdrop`を直接組み立てません。helperは共通DOM、見出し、説明、actions、ARIA参照、backdrop close formだけを担当し、開閉triggerや個別Stimulus controllerの処理を持ちません。`form[method=dialog]`を通常formへ入れ子にしないよう、modal helperの出力は通常formの外へ配置してください。
- `tabs-lift`と`tab-content`を組み合わせる画面では、DOM上の隣接だけでなく、証跡画像上でもactive tabとtabpanelが視覚的に接続していることを確認します。active tabとtabpanelの間に別行のtabが入る折り返し、孤立したtab、borderの分断・重複、tabpanelの上borderがactive tabの下へ透ける表示は不合格です。全体画像だけで判断せず、共有境界を等倍以上で確認し、computed border幅に加えてstacking order上もactive tabが共有境界を覆うことを検証します。
- desktop証跡では、同一tablist内の全tabが同じ行に配置され、active tabの下端とtabpanelの上端が接続していることをcomputed geometryで検証します。
- 参考画像や明示された画面要件と異なる表示を、daisyUIの既定動作やresponsive時の一般的な挙動であることを理由に許容しません。
- visual assertionが失敗した場合、現在の出力を通すためにassertionを弱めたり削除したりしません。要件を変更する必要がある場合は、先にユーザーの承認を得てください。
- `evidence:update`後は変更対象のdesktop・mobile画像を実際に開き、タブの段組み、active tabとtabpanelの接続、border、overflowを個別に確認してから「目視確認済み」と報告してください。
- 狭幅でtabを1段に維持できない場合、折り返しを暗黙に許容せず、horizontal navigationや別のresponsive navigationを設計してください。
- アイコンを使用する場合は、原則として[Heroicons](https://heroicons.com/)のSVGアイコンを利用してください。装飾目的のSVGには`aria-hidden="true"`を設定し、linkやbuttonの意味は隣接するtextまたはaccessible nameで伝えてください。

responsive navigationを変更した場合は、DOM構造のテストだけで完了とせず、組み込みブラウザで最低限、390px幅の未ログインdropdown展開、390px幅のログイン後dropdown展開、390px幅のaccount menu active表示を目視します。さらに320・640・960pxでviewport内へ収まること、961pxでdesktop navigationへ切り替わること、横スクロールがないことをcomputed geometryで確認してください。

機能を追加・変更した場合は、その変更によって`docs/evidence/`の撮影対象に不足や不要なシナリオが生じていないかを必ず検討してください。新しい画面、表示状態、認証・権限別の分岐、重要な操作結果を目視確認する必要がある場合は、選択可能な機能をすべて有効にした日本語sampleの撮影runnerと期待シナリオを適切に追加・変更し、`rake evidence:update`で証跡を更新してください。既存シナリオが不要になった場合も放置せず削除し、`rake evidence:verify`で画像、Markdown、manifest、生成元fingerprintの整合性を確認してください。

## テスト方針

Minitest を使用します。単体テストは `test/unit/`、アプリケーション生成の結合テストは `test/integration/` に配置し、ファイル名は `_test.rb` で終わらせます。`bootstrap.rb` の決定的生成、分割ソースとの同期、キャンセル時の無副作用、選択肢の正規化、実行順序、後始末、空白やシェルメタ文字を含むパスを検証してください。

## コミットとプルリクエスト

現在の履歴では、`docs: define rapid rails template architecture` のような簡潔な Conventional Commits 形式を使用しています。`docs:`、`feat:`、`fix:`、`test:` に命令形の要約を続けてください。

プルリクエストには、問題、構造的な解決方法、影響する選択肢やフェーズ、実施した検証を記載します。関連 Issue をリンクし、振る舞いの実装より先に設計文書を更新してください。分割ソースを変更した場合のみ、同期検証を通過した再生成済み `bootstrap.rb` を含めます。
