# Repository Guidelines

## プロジェクト構成とモジュール配置

ルートにはプロジェクト全体の文書（`README.md`、`CONTRIBUTING.md`）と環境設定（`mise.toml`）があります。設計判断は `docs/adr/`、現在の構成を示す更新可能な参照文書は `docs/reference/` に置きます。`docs/reference/architecture.md` はコンポーネント境界、`docs/reference/options.md` は質問項目の振る舞い、`docs/reference/stack.md` は採用技術、`docs/reference/template-flow.md` は実行順序の正本です。

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

Ruby は2スペースでインデントします。ファイル、メソッド、オプション識別子には `snake_case`、クラスとモジュールには `CamelCase` を使用します。`docs/reference/architecture.md` の責務境界を守り、質問間の依存関係は非巡回にしてください。生成先では構造化補正済み`.rubocop.yml`と`bin/rubocop -a`を使用します。

変更手段は、Rails Generator/Application Template API、ライブラリの generator、構造化データ操作、Prism による AST 編集の順で選びます。grep ベースの書き換え、曖昧な文字列置換、暗黙のフォールバック、Rails 8.1.x／Ruby 4.0.x の対象範囲外に対する互換処理は追加しません。

## オプション選択UI

`bootstrap.rb`の対話的な選択肢と最終確認には、`marcoroth/gum-ruby`が提供する`Gum.choose`と`Gum.confirm`を使用してください。標準入力を直接読み取る独自の選択UIや、gumが利用できない場合の代替UIは追加しません。対応するgum gemのversionと実行可能ファイルを質問開始前に検証し、利用できない場合は明示的に失敗させてください。

## View実装と目視検証

- 生成アプリのUIは`shadcn_view_components` 0.2.0の公開コンポーネントと既定テーマを使用します。HTML構造を持つ要素には`Shadcn::*`を描画し、Rails form helperが生成するinputなどには`Shadcn::Input.classes`のような公開class APIまたは`ShadcnViewComponents::Classes.resolve`を使用します。コンポーネントAPI、variant、`data-slot`は同梱gemの実装を確認してください。
- 色は`background`、`foreground`、`muted`、`border`、`primary`、`destructive`などのsemantic tokenを使います。状態表示のAlertは`Shadcn::Alert`と`Shadcn::Alert::Description`を使用し、エラーには`variant: :destructive`、状態変化には適切な`role`を指定します。Web Pushの状態表示は`data-tone`を切り替えます。
- 生成アプリの通常の文字付き操作button・button相当のlinkは、`ApplicationHelper#action_button_classes(role)`を使用します。許可するroleは`:primary`、`:secondary`、`:quiet`、`:warning`、`:destructive`、`:destructive_confirm`だけです。未知のroleを既定値へ読み替えません。`:warning`は公開outline variantを使い、不可逆処理の確定だけ`:destructive_confirm`を使用します。
- card、form、modal、row内のaction groupは右寄せし、狭幅で折り返せるようにします。DOM順は`quiet`、`secondary`、`warning`、`primary`または`destructive`とし、確認画面の`destructive_confirm`を最後にします。Card内で使える場合は`Shadcn::Card::Footer`を使用します。
- 文字付き操作は通常時にもbuttonまたはlinkと判別できる表示にします。iconだけの慣例的なtriggerにはaccessible nameを付けます。通常の本文linkは下線などで認識できるようにし、navigation内のlinkは配置とactive表示を確認します。
- 通知popover、受信者選択、Copy操作、header、dropdown、icon-only button、modal backdrop、Wallet Providerの操作は`action_button_classes`の対象外です。該当する公開コンポーネントとvariantを直接指定します。table rowを理由に通常の操作buttonを縮小しません。
- ページ全体に作用する追加・絞り込み・一括操作は、Viewで`content_for :page_actions_primary`または`content_for :page_actions_secondary`へ設定します。slotは配置先でありroleや配色ではありません。個別model、table row、formの操作はそのcard、row、form内に残します。standalone scaffoldのindex、new、editにあるheader actionはこの規約の例外です。
- page actionsは共通layout/helperが、640px未満ではsecondaryからprimaryの順に1列、640px以上では左secondary・右primaryの2列で配置します。タブなしでは見出し直下の`Shadcn::Card`内、タブ付きではactive画面のCard::Content先頭へ配置します。View側で同じlayoutを組み立てません。
- 標準の表示面は`Shadcn::Card`を使用し、Card::Contentの既定余白を維持します。端まで表示するtableなど、意図的に余白を変える場合だけ個別に扱います。borderの状態色はsemantic tokenを使用します。ページ移動には`NavigationMenu`、同一画面内のパネル切替には`Tabs`を使い、公開variantを用途で選びます。
- タブ付き画面の画面切り替えには`ApplicationHelper#with_tab`を使用します。これは`Shadcn::NavigationMenu`とactive画面の`Shadcn::Card`を描画します。active判定は各項目のpath prefix、または`is_active` lambdaで指定します。項目は1段で横スクロール可能にし、View側で同じnavigationを再構築しません。tabpanelを伴わないselectorは対象外です。
- dialogは`ApplicationHelper#with_modal`を使用します。共通helperは`Shadcn::Dialog`のDOM、見出し、説明、actions、ARIA参照、閉じる操作を担当します。開閉triggerと個別Stimulus controllerの処理は呼び出し側に残します。通常formとdialog内formを入れ子にしません。
- desktop証跡では同じnavigation内の全項目が1行に並び、active項目が見え、Cardがnavigationの下で同じ幅に収まることをcomputed geometryで検証します。狭幅でも項目を折り返さず、navigation内だけを横スクロールさせ、ページ全体に横スクロールを発生させません。
- 参考画像や明示された画面要件と異なる表示を、コンポーネントの既定動作を理由に許容しません。visual assertionが失敗した場合、出力を通すためにassertionを弱めたり削除したりしません。要件を変更する必要がある場合は先にユーザーの承認を得てください。
- `evidence:update`後は変更対象のdesktop・mobile画像を実際に開き、navigationの段組み、active表示、border、overflowを個別に確認してから「目視確認済み」と報告してください。
- responsive navigationを変更した場合は、組み込みブラウザで390px幅の未ログイン・ログイン後dropdown展開とaccount menu active表示を目視します。320・640・960pxでviewport内へ収まること、961pxでdesktop navigationへ切り替わること、横スクロールがないことをcomputed geometryで確認します。
- 機能を追加・変更した場合は`docs/evidence/`の撮影対象を見直します。新しい画面や状態があれば、全機能を有効にした日本語sampleのrunnerと期待シナリオを更新し、`rake evidence:update`と`rake evidence:verify`を実行します。不要になったシナリオは削除します。
- アイコンは原則としてHeroiconsのSVGを使用します。装飾SVGには`aria-hidden="true"`を指定し、操作の意味はtextまたはaccessible nameで伝えます。

## テスト方針

Minitest を使用します。単体テストは `test/unit/`、アプリケーション生成の結合テストは `test/integration/` に配置し、ファイル名は `_test.rb` で終わらせます。`bootstrap.rb` の決定的生成、分割ソースとの同期、キャンセル時の無副作用、選択肢の正規化、実行順序、後始末、空白やシェルメタ文字を含むパスを検証してください。

## コミットとプルリクエスト

現在の履歴では、`docs: define rapid rails template architecture` のような簡潔な Conventional Commits 形式を使用しています。`docs:`、`feat:`、`fix:`、`test:` に命令形の要約を続けてください。

プルリクエストには、問題、構造的な解決方法、影響する選択肢やフェーズ、実施した検証を記載します。関連 Issue をリンクし、振る舞いの実装より先に設計文書を更新してください。分割ソースを変更した場合のみ、同期検証を通過した再生成済み `bootstrap.rb` を含めます。
