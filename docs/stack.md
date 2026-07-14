# 採用技術とセットアップ要件

この文書は、生成するRailsアプリケーションへ必ず導入する技術と、対話結果に応じて導入する技術を定義します。現在は要件定義段階であり、Gemや設定を追加するコードはまだ実装していません。

## 固定構成

| 分類 | 採用技術・Gem | 方針 |
| --- | --- | --- |
| データベース | SQLite（`sqlite3`） | 開発・テスト・productionで使用する |
| Webサーバー | Puma | RailsアプリケーションのWebプロセスとして使用する |
| Asset Pipeline | `propshaft` | Sprocketsへ切り替えない |
| JavaScript配布 | `importmap-rails` | Node.jsを前提とするJS bundlerを導入しない |
| Hotwire | `turbo-rails`、`stimulus-rails` | TurboとStimulusを使用する |
| CSS | `tailwindcss-rails` | Rails統合版Tailwind CSSを使用する |
| テスト | Minitest | Rails標準のtest frameworkを維持する |
| システムテスト | `capybara`、`capybara-playwright-driver` | SeleniumではなくPlaywright driverを使用する |
| fixture/factory | `factory_bot`、`factory_bot_rails` | テストデータ生成にFactory Botを使用する |
| ページネーション | `pagy` | ページネーションの標準実装とする |
| active link | `active_link_to` | 現在ページに応じたリンク表示に使用する |
| 認可 | `action_policy` | authorization policyの標準実装とする |
| エラー監視 | `sentry-ruby`、`sentry-rails` | productionのエラー通知と追跡に使用する |

Rails 8.1では、SQLite、Puma、Propshaft、Importmap、Turbo、Stimulus、Minitestが標準構成に含まれます。これらをGemfileへ重複追加せず、対象の`rails new`オプションと生成結果を検証します。Tailwind CSSは`--css=tailwind`を指定し、Railsが提供する`tailwindcss:install`処理を利用します。

Rails標準のシステムテスト構成にはCapybaraとSelenium WebDriverが含まれます。本構成ではCapybaraを維持し、Selenium WebDriverを`capybara-playwright-driver`へ置き換えます。Minitestプロジェクトなので、文書とコードでは「system spec」ではなくRailsの用語に合わせて「システムテスト」と呼びます。

## application gem

次のGemは条件にかかわらず導入します。

```text
pagy
active_link_to
action_policy
sentry-ruby
sentry-rails
```

SentryのDSNやenvironmentなど、秘密情報と環境依存値はリポジトリへ埋め込みません。設定方法は実装フェーズで別途定義します。

## テスト用Gem

```text
capybara
capybara-playwright-driver
factory_bot
factory_bot_rails
```

Playwright driverの登録、browser種別、headless設定、Playwright CLIとbrowser binaryの導入方法は、ローカル環境とCIで同じ結果になるよう実装フェーズで固定します。必要な実行ファイルがない場合にSeleniumへ戻すフォールバックは設けません。

## Linter・Formatter・開発支援

development groupへ次を`require: false`で追加します。

```text
ruby-lsp
ruby-lsp-rails
rubocop-rails
rubocop-thread_safety
momocop
```

Rails標準の`rubocop-rails-omakase`は使用しません。生成後に`bundle remove`するのではなく、`rails new`へ`--skip-rubocop`を渡して最初から生成対象外とし、上記GemをApplication Templateの`gem` APIでbundle install前に宣言します。

`.rubocop.yml`のベースには、次のcommitへ固定されたGistを使用します。

```text
https://gist.githubusercontent.com/supermomonga/3ffe073e1c11cd9025d35d507038b9e2/raw/38a485963395626171243dce796e6dc541d61450/.rubocop.yml
```

外部コマンドの`curl`ではなく、Rails/Thorの`get` actionで取得します。取得失敗時に別URLや内蔵設定へ切り替えません。bundle installと設定完了後に`bin/rubocop -a`を実行し、終了状態を検証します。

### 現在のGistとの差分

固定されたGistは`AllCops.TargetRubyVersion: 3.4`ですが、本プロジェクトの対象はRuby 4.0.xです。また、現在の`rubocop-rails`と`rubocop-thread_safety`はRuboCopの`plugins`設定を案内し、`momocop`は`require`設定を案内しています。

この差分を無視して設定を適用しません。Gistを更新して新しいcommitへ固定し直すか、取得後にYAMLとして構造化編集するかを実装前に決定します。

## Solid Queue

ジョブ管理を使用する場合だけ`solid_queue`を導入し、Active Job adapterを`solid_queue`に設定します。SQLiteではprimary databaseとqueue databaseを分け、`solid_queue:install`が生成するschemaとmigration pathを使用します。

developmentではPumaからSolid Queueを起動します。

```ruby
plugin :solid_queue if ENV.fetch("RAILS_ENV", "development") == "development"
```

productionではPuma pluginを有効化せず、`bin/jobs`をworkerプロセスとして起動します。`deployment == dokploy`の場合だけ`Procfile.prod`へworkerを定義し、Webプロセスと同じコンテナ内でForemanから起動します。`deployment == none`でも`bin/jobs`自体は生成しますが、起動方法をこのテンプレートでは設定しません。

## Action CableとSolid Cable

Action Cableを使用する場合だけ`solid_cable`を導入し、production adapterをSolid Cableにします。

```yaml
production:
  adapter: solid_cable
  connects_to:
    database:
      writing: cable
  polling_interval: 0.1.seconds
  message_retention: 1.day
```

productionの`config/database.yml`には、primary databaseとは別のSQLite cable databaseと`db/cable_migrate`を定義します。Action Cableを使わない構成では、Turbo DriveとTurbo Framesは利用できますが、Action Cableに依存するTurbo Streamsのbroadcast機能は利用できません。

## デプロイ方法

デプロイは固定構成ではなく、`dokploy`または`none`から選択します。既定値は`dokploy`です。

### `dokploy`

Rails標準のDocker/Kamal/Thruster構成は使用せず、`rails new`へ`--skip-docker --skip-kamal --skip-thruster`を渡します。Application Templateが次のproduction専用ファイルを生成します。

```text
Dockerfile.prod
.dockerignore
bin/docker-entrypoint
Procfile.prod
litestream.yml
```

これらは本プロジェクトが管理するsource templateからRails/Thorの`template` actionで生成します。Rails標準Dockerfileを生成してから文字列置換する方式は採用しません。

Dokployではbuild typeをDockerfile、Dockerfile pathを`Dockerfile.prod`に設定します。コンテナの既定commandがLitestreamとForemanを起動するため、Dokploy側でweb/worker commandを個別に上書きしません。

#### Docker image

`Dockerfile.prod`はRuby 4.0.6 slim imageを使うmulti-stage buildとします。

- base stageでproduction用Bundler環境とLitestreamを用意する。
- build stageでGemをinstallし、`SECRET_KEY_BASE_DUMMY=1`でassetsをprecompileする。
- final stageには実行時Gem、SQLite、libvips、jemalloc、Litestream、アプリケーションだけを含める。
- `/data`をvolumeとして宣言し、SQLite databaseをimage layerやephemeral filesystemへ保存しない。
- `PORT=3000`でPumaを公開する。
- YJITとjemallocを有効化する。
- entrypointを`bin/docker-entrypoint`へ固定する。
- 既定commandでLitestreamのreplicationを開始し、その`-exec`から`bundle exec foreman start --procfile=Procfile.prod`を実行する。

Litestreamは`0.5.14`へ固定し、linux/amd64とlinux/arm64のrelease assetをDockerのtarget architectureに応じて選択します。releaseの`checksums.txt`でdownloadしたassetを検証してからinstallし、検証失敗時に別versionや未検証binaryへ切り替えません。

#### production process

`foreman` gemは`deployment == dokploy`の場合だけ、productionで実行できるgroupへ`require: false`で追加します。`Procfile.prod`には必ずWebプロセスを定義します。

```procfile
web: bundle exec puma -p 3000 -C ./config/puma.rb
```

`active_job == solid_queue`の場合だけworkerを追加します。

```procfile
worker: bin/jobs --mode async
```

Pumaは`RAILS_MAX_THREADS`を既定5、`WEB_CONCURRENCY`を既定2として設定します。productionではSolid Queue Puma pluginを有効化しません。

#### SQLite database

productionのSQLite databaseは、次の環境変数で`/data`配下へ配置します。

| database | 環境変数 | 既定の配置例 | 条件 |
| --- | --- | --- | --- |
| primary | `DATABASE_PATH` | `/data/production.sqlite3` | 常に必要 |
| queue | `QUEUE_DATABASE_PATH` | `/data/production_queue.sqlite3` | Solid Queue使用時 |
| cable | `CABLE_DATABASE_PATH` | `/data/production_cable.sqlite3` | Action Cable使用時 |

SQLite共通設定は`transaction_mode: immediate`、`timeout: 20000`とし、connection poolは`DATABASE_POOL_SIZE`、未指定時は`RAILS_MAX_THREADS`を使用します。queueには`db/queue_migrate`、cableには`db/cable_migrate`を`migrations_paths`として設定します。

`bin/docker-entrypoint`は必要なdirectoryを作成した後、`bundle exec rails db:prepare`を一度実行します。Rails 8.1の`db:prepare`は現在のenvironmentに定義された全databaseを初期化・migrateするため、tableの有無を独自に調べるrunnerやdatabase別の非公開処理は追加しません。失敗時はコンテナを起動せず終了します。

#### Litestream

Litestreamはproduction SQLite databaseをS3互換storageへreplicateします。`litestream.yml`には選択済みdatabaseだけを含めます。

- primaryは常にreplication対象とする。
- Solid Queue使用時だけqueueを追加する。
- Action Cable使用時だけcableを追加する。

各databaseは別のreplica URLを使い、認証情報をファイルへ埋め込みません。

| 用途 | 環境変数 |
| --- | --- |
| primary replica | `LITESTREAM_REPLICA_URL` |
| queue replica | `LITESTREAM_QUEUE_REPLICA_URL` |
| cable replica | `LITESTREAM_CABLE_REPLICA_URL` |
| access key | `LITESTREAM_ACCESS_KEY_ID` |
| secret key | `LITESTREAM_SECRET_ACCESS_KEY` |

Litestreamの設定または認証情報が不足した場合、replicationなしでRailsだけを起動するフォールバックは行いません。

#### Dokploy設定

- build type: Dockerfile
- Dockerfile path: `Dockerfile.prod`
- container port: `3000`
- persistent volume mount: `/data`
- container command: Dockerfileの既定commandを使用
- 必須secret: `RAILS_MASTER_KEY`、Litestreamのaccess keyとsecret key
- 必須database path: `DATABASE_PATH`と、選択に応じた`QUEUE_DATABASE_PATH`／`CABLE_DATABASE_PATH`
- 必須replica URL: primaryと、選択に応じたqueue／cableのLitestream URL
- 任意の調整値: `WEB_CONCURRENCY`、`RAILS_MAX_THREADS`、`DATABASE_POOL_SIZE`、`JOB_CONCURRENCY`

環境変数の実値や秘密情報を生成先リポジトリへ保存しません。

### `none`

`Dockerfile.prod`、`.dockerignore`、production用`bin/docker-entrypoint`、`Procfile.prod`、`litestream.yml`、Kamal、Thruster、Dokploy固有設定を生成しません。`foreman`も追加しません。アプリケーション自体のPuma設定や、選択したSolid Queueの`bin/jobs`は維持します。

## Rails 8.1のSolid系既定値

Rails 8.1は、skip optionを指定しない場合に`solid_cache`、`solid_queue`、`solid_cable`をまとめて生成します。本プロジェクトではSolid QueueとSolid Cableがユーザー選択なので、Rails既定の一括導入をそのまま利用できません。

`rails new`開始前にSolid系のgenerator optionを確定し、選択したcomponentだけを公式install generatorで導入します。Solid Cacheを固定で使うか、別の選択肢にするかは未決事項です。

## 実装前に決定する事項

- PWA、Web Push、Solid Queue、Action Cableの既定値
- アカウント管理方法の既定値
- WalletConnect選択時の署名challenge、nonce、session、chain検証の仕様
- PWAを使わない場合にRails標準のPWA stubを残すか削除するか
- Solid Cacheを使うかどうか
- `.rubocop.yml`のGistを更新するか、取得後に構造化編集するか
