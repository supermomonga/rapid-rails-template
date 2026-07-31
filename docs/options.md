# 対話オプションの定義方針

この文書は、Rapid Rails Templateへ対話的な選択肢を追加するときの記録形式と設計規則を定義します。固定技術スタックは[採用技術とセットアップ要件](stack.md)を参照してください。

## 必須項目

各オプションは、次の項目を文書化します。

| 項目 | 内容 |
| --- | --- |
| 識別子 | `snake_case`の一意な内部識別子 |
| 質問文 | 利用者へ表示する日本語の質問 |
| 選択肢 | 選択可能な値と、それぞれの意味 |
| 既定値 | 明示的な既定値。既定値を持たない場合はその理由 |
| 表示条件 | 先に収集した回答に基づく質問の表示条件 |
| 影響する処理 | 実行計画へ追加または除外するstep |

## 記録テンプレート

新しいオプションは、次の形式でこの文書へ追加します。

```markdown
## `<option_id>`

- 質問文:
- 選択肢:
- 既定値:
- 表示条件:
- 影響する処理:
```

## 設計規則

- アプリ名の自由入力には`gum` 0.3.2の`Gum.input`、対話的な選択には`Gum.choose`、最終確認には`Gum.confirm`を使用する。標準入力を直接読む独自UIや代替UIは持たない。
- 各質問は仕様上の既定値をGumの選択済み項目として渡し、Gumが返した選択肢だけを回答として扱う。選択をキャンセルした場合は生成を開始せず終了する。
- 各オプションは、識別子の`_`を`-`に変換したCLI引数`--OPTION=VALUE`で個別に指定できる。
- CLI引数で指定した回答は再質問せず、未指定の適用可能な項目だけを依存順に質問する。
- すべての適用可能な項目がCLI引数で確定済みの場合は、対話と最終承認を行わず実行計画を表示して開始する。
- すべての適用可能な質問は、`rails new`や一時ファイル作成を開始する前に完了させる。
- 質問中は後続質問の表示条件だけを評価し、対話UI用のGum実行可能ファイル以外の外部command、Gem追加、step構築、file actionを実行しない。
- 全質問の完了後に回答を正規化・検証し、実行開始前に変更不能な設定として確定する。
- 表示条件は、それ以前に確定した回答だけを参照する。
- 質問の依存関係は循環を許さない。有向非巡回グラフとして解決可能な順序を持たせる。
- 質問を表示しなかった場合の値を暗黙に推測しない。必要なら仕様として既定値を定義する。
- 選択肢の追加時に、実行予定へ現れる説明と対象stepを同時に定義する。
- 外部コマンドの有無や処理失敗を理由に、別の選択肢へ自動的に切り替えない。
- 対応範囲外のRailsまたはRuby向け選択肢を追加しない。

## アプリ名

- CLI引数: `--name=NAME`
- 質問文: アプリ名を入力してください。
- 初期値: `APP_PATH`のbasename
- 表示条件: `--name`が未指定の場合
- 影響する処理: `rails new`へ単一引数`--name=NAME`として渡す

アプリ名は有限選択の設定値とは分離して扱います。キャンセルまたは空入力は生成開始前に拒否し、Rails固有の正規化と妥当性判定は対象versionのRails 8.1へ委ねます。

## 質問順序

質問は次の順序で行います。後続の表示条件と`Auto`判定は、前に確定した回答だけを参照します。

1. アプリ名
2. PWAを使うか
3. PWAでWeb Pushを使うか
4. ジョブ管理を使うか
5. Solid Cacheを使うか
6. アカウント管理方法
7. API機能を有効にするか
8. Action Cableを使うか
9. メール機能
10. Action Textを使うか
11. デプロイ方法

この順序で適用可能な質問をすべて完了するまで、実行予定の確認へ進みません。表示条件を満たさない質問は利用者へ表示せず、全質問完了後の正規化で仕様どおりの値を設定します。

## 最終確認

全質問の完了後に、次の順序で最終確認内容を構築します。

1. 未回答、無効値、選択肢間の矛盾を検証する。
2. `Auto`と非適用項目を実効値へ正規化する。
3. アプリ名、`rails new`のgenerator option、Gem、step、生成物、production processを確定する。
4. アプリ名、質問時の回答、実効値、解決理由、実行予定を一覧表示する。
5. 利用者へ一度だけ最終承認を求める。

最終承認は既定値を拒否とする`Gum.confirm`で行います。承認されなければ副作用なしで終了します。承認後は回答、実効値、実行順序を変更せず、追加質問も行いません。

## `pwa`

- CLI引数: `--pwa=use|skip`
- 質問文: PWAを使用しますか？
- 選択肢: `use`、`skip`
- 既定値: `skip`
- 表示条件: 常に表示する
- 影響する処理: PWA manifest、service worker、関連routeの有効化と無効時のstub取扱い

Rails 8.1にはPWA専用の`--skip-pwa`がなく、PWA用stubが標準生成されます。`skip`時もstubは残します。存在しないgenerator optionや曖昧な文字列編集では処理しません。

## `web_push`

- CLI引数: `--web-push=use|skip`
- 質問文: PWAでWeb Pushを使用しますか？
- 選択肢: `use`、`skip`
- 既定値: `skip`
- 表示条件: `pwa == use`
- 影響する処理: `use`の場合だけ`web-push` gemを追加し、Web Push設定stepを実行する

`pwa == skip`の場合は質問せず、値を`skip`へ正規化します。`use`の場合はVAPID鍵を自動生成し、git管理外の`mise.local.toml`の`[env]`へ`VAPID_PUBLIC_KEY`と`VAPID_PRIVATE_KEY`として保存します。

## `active_job`

- CLI引数: `--active-job=solid_queue|skip`
- 質問文: ジョブ管理を使用しますか？
- 選択肢: `solid_queue`、`skip`
- 既定値: `skip`
- 表示条件: 常に表示する
- 影響する処理: `solid_queue` gemとinstall generator、SQLite queue database、Active Job adapter、development用Puma plugin、production worker

`solid_queue`の場合、`config.active_job.queue_adapter = :solid_queue`を設定します。developmentではPuma pluginを有効化し、productionではPumaから起動しません。`deployment == dokploy`の場合は`Procfile.prod`のworkerプロセスで`bin/jobs --mode async`を実行し、`deployment == none`の場合はproductionでの起動方法を設定しません。

## `account_authentication`

- CLI引数: `--account-authentication=devise|wallet_siwe`
- 質問文: アカウント管理方法を選択してください。
- 選択肢: `devise`、`wallet_siwe`
- 既定値: `devise`
- 表示条件: 常に表示する
- 影響する処理: Deviseのinstall・model生成、またはRails組み込み認証基盤、`siwe-rb`、Web3.jsを使うEVM wallet認証処理

`devise`はメールアドレスとパスワードによる登録・ログインを提供します。`wallet_siwe`はWalletConnectや外部SaaSを使用せず、注入済みEIP-1193 provider、Web3.js 4.16.0、`siwe-rb` 0.2.xでSIWEを提供します。Railsが17文字のnonceを生成してsessionへ保存し、5分以内の一回限りのchallengeとして検証します。domain、URI、nonce、署名、正のchain IDを検証し、成功時は小文字化したEVM addressだけを一意なUser識別子にします。chain IDはUser識別子に含めないため、同じaddressはどのEVM互換chainでも同一アカウントです。Deviseアカウントとの紐付けは行いません。

どちらの認証方式でもhomeは公開し、account画面を認証必須とします。guest向け認証画面にはauthentication layout、account画面にはaccount layoutを適用します。Wallet SIWEのsession resourceは`new`、`create`、`destroy`だけに制限し、controllerに存在しない`show`、`edit`、`update` routeは生成しません。Wallet SIWEのaccount resourceは`show`、`edit`、`destroy`を公開し、wallet addressはプロフィールではなくアカウント設定に表示します。削除確認後にUserと従属する全Sessionを削除し、homeへ戻します。

## `profile_features`

- CLI引数: `--profile-features=screen_name,display_name,avatar`
- 質問文: プロフィール機能を選択してください。
- 選択肢: `screen_name`、`display_name`、`avatar`の複数選択
- 既定値: 3機能すべて
- 表示条件: 常に表示する
- 影響する処理: Profile model・1対1 User association・プロフィール表示／編集画面・headerの認証後メニュー・Active Storage

対話UIは`Gum.choose(..., no_limit: true)`を使用し、3項目を選択済みとして表示します。何も選択しない回答は有効です。CLIではカンマ区切りで指定し、`--profile-features=`を何も選択しない回答として扱います。未知の値、重複値、空要素を含む値は生成開始前に拒否します。

1つ以上を選択した場合だけ、Userと1対1のProfile model、表示画面、編集画面、更新処理、account navigationの「プロフィール」を生成します。ProfileはUser作成時に同時作成し、User削除時に従属削除します。

`screen_name`を選択した場合はHaikunatorで小文字の英単語と数字をアンダースコアで連結した値をUser作成時に自動生成し、必須かつ一意にします。入力できる文字も小文字の英数字とアンダースコアだけに制限します。`display_name`を選択した場合もUser作成時にHaikunator由来の値を自動生成し、必須かつ一意な公開表示名として扱います。両方を選択した場合は、先に一意な`screen_name`を生成し、その値をCamelCaseへ変換した同一由来の値を`display_name`に設定します。databaseには各選択済みcolumnの`NOT NULL`制約とunique indexを作成し、modelでもpresenceとuniquenessを検証します。

`avatar`を選択した場合だけ`boring_avatars ~> 0.1.0`とActive Storageを導入し、Profileへ`has_one_attached :avatar`を追加します。画像未設定時はUser IDの文字列表現をseedとして、`marble` variantとRapid Rails theme palette（`#3ea8ff`、`#0f83fd`、`#10b981`、`#f59e0b`、`#f43f5e`）からBoring Avatar SVGを生成します。seed専用columnは追加しません。設定済み画像はプロフィール編集画面の独立した確認付き操作で削除でき、削除後はBoring Avatarへ戻ります。

認証後のheader menu triggerは、設定済み画像またはBoring Avatarとし、クリックとhoverの両方で展開します。プロフィール詳細も同じ共通helperを使用します。`avatar`を選択しない場合はHeroiconsの`bars-3`と`MENU` textをtriggerにします。展開内容は、選択済みなら`display_name`と`screen_name`、account navigationと同じ項目群、ログアウトの順です。

何も選択しなかった場合はProfile model、migration、controller、route、View、test fixtureを生成しません。header menuは`bars-3` + `MENU`を使い、account navigationからプロフィール項目を除外します。

## `api`

- CLI引数: `--api=enable|disable`
- 質問文: API機能を有効にしますか？
- 選択肢: `enable`、`disable`
- 既定値: `enable`
- 表示条件: 常に表示する
- 影響する処理: `/api` namespace、Bearer token認証基盤、`ApiCredential` modelとAPI/Web CRUD、マイページのAPIキー管理画面

`enable`では、`Api::ApiController`を`ActionController::API`基盤の共通controllerとして生成し、`Authorization: Bearer <api_key>.<api_secret>`を検証します。`api_secret`は生成時と再発行時に一度だけ返し、databaseにはSHA-256 digestだけを保存します。照合には定数時間比較を使い、認証済みcredentialが属するUserのデータだけを操作します。

`Api::ApiCredentialsController`は`/api/api_credentials`でCRUDと`revoke`を提供します。マイページ側の`ApiCredentialsController`も同じUser所有scopeでCRUDし、「APIキーの管理」から作成、表示、名称変更、削除、ApiSecretのrevoke（新しいsecretへの再発行）を行えます。API key自体はcredentialを識別する公開値として維持し、revokeではsecretだけを差し替えます。一覧画面と詳細画面ではAPI keyをreadonly inputとコピーボタンで表示し、ApiSecretも作成・再発行直後に限って同じコピーUIで一度だけ表示します。Bearer tokenは画面には表示しません。`disable`ではmodel、migration、controller、route、View、メニュー項目を生成しません。

## `solid_cache`

- CLI引数: `--solid-cache=use|skip`
- 質問文: Solid Cacheを使用しますか？
- 選択肢: `use`、`skip`
- 既定値: `use`
- 表示条件: 常に表示する
- 影響する処理: `solid_cache` gem、install generator、production cache database

## `action_cable`

- CLI引数: `--action-cable=solid_cable|skip`
- 質問文: Action Cableを使用しますか？
- 選択肢: `solid_cable`、`skip`
- 既定値: `skip`
- 表示条件: 常に表示する
- 影響する処理: RailsのAction Cable生成option、`solid_cable` gemとinstall generator、production cable databaseと`cable.yml`

`solid_cable`の場合、productionだけSolid Cable adapterを使用します。`skip`の場合は`rails new`へ`--skip-action-cable`を渡し、Action Cableに依存するTurbo Streamsのbroadcast機能が利用できないことを実行予定に表示します。

## `mail`

- CLI引数: `--mail=auto|use|skip`
- 質問文: メール機能を使用しますか？
- 選択肢: `auto`、`use`、`skip`
- 既定値: `auto`
- 表示条件: 常に表示する
- 影響する処理: Action MailerとAction Mailboxのgenerator option

`auto`は`account_authentication == devise`の場合に`use`、それ以外の場合に`skip`へ正規化します。`skip`の場合は`rails new`へ`--skip-action-mailer --skip-action-mailbox`を渡します。確認画面には`auto`ではなく、正規化後の実効値と理由を表示します。

## `action_text`

- CLI引数: `--action-text=use|skip`
- 質問文: Action Textを使用しますか？
- 選択肢: `use`、`skip`
- 既定値: `use`
- 表示条件: 常に表示する
- 影響する処理: Action Textのgenerator option

`skip`の場合は`rails new`へ`--skip-action-text`を渡します。

## `deployment`

- CLI引数: `--deployment=dokploy|none`
- 質問文: デプロイ方法を選択してください。
- 選択肢: `dokploy`、`none`
- 既定値: `dokploy`
- 表示条件: 常に表示する
- 影響する処理: Docker関連のgenerator option、production用Docker/Procfile/Litestream、Dokploy設定

`dokploy`ではRails標準のDocker/Kamal/Thrusterを使用しません。`rails new`へ`--skip-docker --skip-kamal --skip-thruster`を渡し、Application Templateから`Dockerfile.prod`、`.dockerignore`、`bin/docker-entrypoint`、`Procfile.prod`、`litestream.yml`を生成します。`foreman`をproductionで利用できるGemとして追加し、LitestreamをDocker imageへinstallします。

`none`でも`rails new`へ`--skip-docker --skip-kamal --skip-thruster`を渡しますが、production用Dockerfile、Procfile、Litestream設定、`foreman`、Dokploy固有設定を追加しません。

`dokploy`を選択した場合は`Procfile.prod`へPumaのwebプロセスを定義し、`active_job == solid_queue`の場合だけworkerプロセスも追加します。コンテナの既定commandがLitestream経由でForemanを起動し、Foremanが`Procfile.prod`のプロセスを管理します。

primary SQLite databaseは常にLitestreamのreplication対象とし、queueとcableは対応する機能を選択した場合だけ追加します。必要なdatabase path、replica URL、S3互換storageの認証情報が不足した場合は実行を失敗させます。

## テスト要件

- 各選択肢と既定値が正規化後の設定へ正しく反映されること。
- CLI引数で指定した項目を再質問せず、未指定の適用可能な項目だけを質問すること。
- `profile_features`をGumの複数選択で収集し、選択なしを有効な回答として扱うこと。
- `--profile-features`のカンマ区切り値を正規化し、空値でProfile関連生成物をすべて省略すること。
- `avatar`選択時だけBoring AvatarsとActive Storageを導入し、User ID由来の既定アバター、header trigger、画像削除routeを生成すること。
- 設定済み画像がBoring Avatarより優先され、削除後は同じUser ID由来のBoring Avatarへ戻ること。
- すべての適用可能な項目をCLI引数で指定した場合、標準入力を読まずに実行すること。
- 表示条件が満たされない質問を行わないこと。
- すべての適用可能な質問を一度ずつ完了するまで最終確認へ進まないこと。
- 質問の依存関係に循環がある場合、ランチャーのbuildまたは起動時検証で拒否すること。
- 質問中と最終確認待ちでは、生成先、一時ファイル、Gemfile、外部commandへ副作用がないこと。
- 無効値や矛盾する組み合わせを変更開始前に拒否すること。
- 選択結果に対応するstepだけが実行計画へ追加されること。
- 最終確認で中止した場合、どの選択結果でもテンプレート固有の変更を開始しないこと。
- 最終確認に質問時の回答、正規化後の実効値、解決理由、全実行予定が表示されること。
- 承認後に質問が行われず、確定済み設定と実行計画が変化しないこと。
- `mail == auto`がDeviseでは`use`、SIWE wallet認証では`skip`へ正規化されること。
- PWAを使わない場合、Web Pushを質問せず`web-push` gemを追加しないこと。
- Solid Queueを使わない場合、queue database、Puma plugin、production workerを生成しないこと。
- Action Cableを使わない場合、Solid Cableとcable databaseを生成しないこと。
- `deployment == dokploy`で`Dockerfile.prod`、`Procfile.prod`、entrypoint、Litestream設定を生成し、Rails標準Docker、Kamal、Thrusterを生成しないこと。
- `deployment == none`でDocker、Kamal、Thruster、Procfile、Litestream、`foreman`を生成・追加しないこと。
- `deployment == dokploy`かつ`active_job == solid_queue`の場合だけ`Procfile.prod`へworkerを追加すること。
- `deployment == dokploy`でprimaryを常にreplicateし、queueとcableを選択に応じて追加すること。
