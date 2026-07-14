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

- すべての適用可能な質問は、`rails new`や一時ファイル作成を開始する前に完了させる。
- 質問中は後続質問の表示条件だけを評価し、Gem追加、step構築、file action、外部commandを実行しない。
- 全質問の完了後に回答を正規化・検証し、実行開始前に変更不能な設定として確定する。
- 表示条件は、それ以前に確定した回答だけを参照する。
- 質問の依存関係は循環を許さない。有向非巡回グラフとして解決可能な順序を持たせる。
- 質問を表示しなかった場合の値を暗黙に推測しない。必要なら仕様として既定値を定義する。
- 選択肢の追加時に、実行予定へ現れる説明と対象stepを同時に定義する。
- 外部コマンドの有無や処理失敗を理由に、別の選択肢へ自動的に切り替えない。
- 対応範囲外のRailsまたはRuby向け選択肢を追加しない。

## 質問順序

質問は次の順序で行います。後続の表示条件と`Auto`判定は、前に確定した回答だけを参照します。

1. PWAを使うか
2. PWAでWeb Pushを使うか
3. ジョブ管理を使うか
4. Solid Cacheを使うか
5. アカウント管理方法
6. Action Cableを使うか
7. メール機能
8. Action Textを使うか
9. デプロイ方法

この順序で適用可能な質問をすべて完了するまで、実行予定の確認へ進みません。表示条件を満たさない質問は利用者へ表示せず、全質問完了後の正規化で仕様どおりの値を設定します。

## 最終確認

全質問の完了後に、次の順序で最終確認内容を構築します。

1. 未回答、無効値、選択肢間の矛盾を検証する。
2. `Auto`と非適用項目を実効値へ正規化する。
3. `rails new`のgenerator option、Gem、step、生成物、production processを確定する。
4. 質問時の回答、実効値、解決理由、実行予定を一覧表示する。
5. 利用者へ一度だけ最終承認を求める。

承認されなければ副作用なしで終了します。承認後は回答、実効値、実行順序を変更せず、追加質問も行いません。

## `pwa`

- 質問文: PWAを使用しますか？
- 選択肢: `use`、`skip`
- 既定値: `skip`
- 表示条件: 常に表示する
- 影響する処理: PWA manifest、service worker、関連routeの有効化と無効時のstub取扱い

Rails 8.1にはPWA専用の`--skip-pwa`がなく、PWA用stubが標準生成されます。`skip`時もstubは残します。存在しないgenerator optionや曖昧な文字列編集では処理しません。

## `web_push`

- 質問文: PWAでWeb Pushを使用しますか？
- 選択肢: `use`、`skip`
- 既定値: `skip`
- 表示条件: `pwa == use`
- 影響する処理: `use`の場合だけ`web-push` gemを追加し、Web Push設定stepを実行する

`pwa == skip`の場合は質問せず、値を`skip`へ正規化します。`use`の場合はVAPID鍵を自動生成し、git管理外の`mise.local.toml`の`[env]`へ`VAPID_PUBLIC_KEY`と`VAPID_PRIVATE_KEY`として保存します。

## `active_job`

- 質問文: ジョブ管理を使用しますか？
- 選択肢: `solid_queue`、`skip`
- 既定値: `skip`
- 表示条件: 常に表示する
- 影響する処理: `solid_queue` gemとinstall generator、SQLite queue database、Active Job adapter、development用Puma plugin、production worker

`solid_queue`の場合、`config.active_job.queue_adapter = :solid_queue`を設定します。developmentではPuma pluginを有効化し、productionではPumaから起動しません。`deployment == dokploy`の場合は`Procfile.prod`のworkerプロセスで`bin/jobs --mode async`を実行し、`deployment == none`の場合はproductionでの起動方法を設定しません。

## `account_authentication`

- 質問文: アカウント管理方法を選択してください。
- 選択肢: `devise`、`wallet_siwe`
- 既定値: `devise`
- 表示条件: 常に表示する
- 影響する処理: Deviseのinstall・model生成、またはRails組み込み認証基盤、`siwe-rb`、Web3.jsを使うEVM wallet認証処理

`devise`はメールアドレスとパスワードによる登録・ログインを提供します。`wallet_siwe`はWalletConnectや外部SaaSを使用せず、注入済みEIP-1193 provider、Web3.js 4.16.0、`siwe-rb` 0.2.xでSIWEを提供します。Railsが17文字のnonceを生成してsessionへ保存し、5分以内の一回限りのchallengeとして検証します。domain、URI、nonce、署名、正のchain IDを検証し、成功時は小文字化したEVM addressだけを一意なUser識別子にします。chain IDはUser識別子に含めないため、同じaddressはどのEVM互換chainでも同一アカウントです。Deviseアカウントとの紐付けは行いません。

どちらの認証方式でもhomeは公開し、`/account`だけを認証必須とします。guest向け認証画面にはauthentication layout、account画面にはaccount layoutを適用します。Wallet SIWEのsession resourceは`new`、`create`、`destroy`だけに制限し、controllerに存在しない`show`、`edit`、`update` routeは生成しません。

## `solid_cache`

- 質問文: Solid Cacheを使用しますか？
- 選択肢: `use`、`skip`
- 既定値: `use`
- 表示条件: 常に表示する
- 影響する処理: `solid_cache` gem、install generator、production cache database

## `action_cable`

- 質問文: Action Cableを使用しますか？
- 選択肢: `solid_cable`、`skip`
- 既定値: `skip`
- 表示条件: 常に表示する
- 影響する処理: RailsのAction Cable生成option、`solid_cable` gemとinstall generator、production cable databaseと`cable.yml`

`solid_cable`の場合、productionだけSolid Cable adapterを使用します。`skip`の場合は`rails new`へ`--skip-action-cable`を渡し、Action Cableに依存するTurbo Streamsのbroadcast機能が利用できないことを実行予定に表示します。

## `mail`

- 質問文: メール機能を使用しますか？
- 選択肢: `auto`、`use`、`skip`
- 既定値: `auto`
- 表示条件: 常に表示する
- 影響する処理: Action MailerとAction Mailboxのgenerator option

`auto`は`account_authentication == devise`の場合に`use`、それ以外の場合に`skip`へ正規化します。`skip`の場合は`rails new`へ`--skip-action-mailer --skip-action-mailbox`を渡します。確認画面には`auto`ではなく、正規化後の実効値と理由を表示します。

## `action_text`

- 質問文: Action Textを使用しますか？
- 選択肢: `use`、`skip`
- 既定値: `use`
- 表示条件: 常に表示する
- 影響する処理: Action Textのgenerator option

`skip`の場合は`rails new`へ`--skip-action-text`を渡します。

## `deployment`

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
