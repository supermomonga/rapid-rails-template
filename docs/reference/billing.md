# サブスク決済

## 境界と対象

全生成アプリに`engines/billing`の`Billing::Engine`とSolid Queueを配置する。運営者プランは管理者、販売者プランはUserごとのMerchantProfileが管理する。MerchantProfileは公開ID、表示名、紹介文、画像を持ち、通常のProfileと分離する。販売主体は作成後に変更しない。

公開画面は`/billing`、購入者・販売者画面は`/account/billing`、管理画面は`/admin/billing`に置く。Engineを一度だけmountし、ホストの認証、Admin::BaseController、Action Policy、共通layout/helper、通知を利用する。`Billing::Access.active?(user:, plan:, at:)`は利用可否だけを返し、有料機能の認可はホストが担当する。

| チェーン | chain ID | 通貨 | ガス通貨 |
| --- | --- | --- | --- |
| Arbitrum | 42161 | CircleネイティブUSDC | ETH |
| Base | 8453 | CircleネイティブUSDC | ETH |
| Ethereum | 1 | CircleネイティブUSDC | ETH |
| Polygon | 137 | CircleネイティブUSDC | POL |

ログイン方法から支払用Base Accountを分離する。プラン価格は全チェーン共通の固定USDC数量で、受付チェーンはプランごとに選択する。USDC.e、他通貨、暦月課金、従量課金は扱わない。

## 契約と利用期間

契約に価格、固定日数、当初の開始日時、チェーン、ウォレット、支払許可を保存する。同一User・同一プランの有効な契約は一つに限り、別プランの併用は許可する。価格・周期の変更は新規契約だけに適用する。プラン受付停止も新規契約だけに作用する。

初回は前払いで、`finalized`を確認してから利用可能にする。確定待ちを含めて当初の開始日時を基準に周期を固定し、支払遅延でずらさない。更新時は猶予中も利用可能とする。猶予の初期値は72時間、アプリ全体で設定し、受付中のプランと有効契約の周期より短いことを検証する。

解約は次回以降の請求を止め、支払済み期間を維持する。送信済みの請求が後から成功した場合はその期間も提供する。猶予終了後は終了し、再開には再契約が必要になる。許可取消は非同期で追跡し、取引結果が不明なまま完了扱いにしない。ウォレット・チェーンの変更は解約して利用期間終了後に再契約する。

## オンチェーン処理

既存のSpendPermissionManagerと標準CoinbaseSmartWalletを使用する。独自コントラクトは作らない。サーバーが支払許可の全項目を組み立て、Base Accountで署名する。スマートアカウント署名の検証は共有コントラクトに委ね、SIWEのEOA検証を流用しない。

標準Factoryで作る集金口座が、必要な承認登録、spend、各USDC送金をexecuteBatchで一括実行する。1周期の許可額はプラン価格と一致させる。運営者プランは全額を運営者へ、販売者プランは運営手数料と残額をそれぞれ送金する。USDCは6桁の最小単位の整数、手数料率はbasis pointsで保持する。初期手数料率は100 bps（1%）で端数切捨て、残額は販売者に帰属する。

手数料率・送金先は請求開始時に保存し、設定変更は次回請求から適用する。実行鍵は環境ごとに一つ、nonceはチェーンごとに管理する。送信前に署名済み取引・nonce・hashを保存し、通信結果不明時は同じ取引を照合・再送する。未確定を失敗と解釈して別の請求を開始しない。receipt、イベント、canonical block、finalizedを確認する。

ガス代は運営者が負担する。チェーンごとの見積上限をnative通貨で必須設定し、超過時は送信保留・管理者通知とする。実費の完全な上限保証ではない。RPC、実行鍵は既存のdestination別1Password/Kamal設定で扱い、秘密をDBや画面に保存・表示しない。集金口座は明示的な管理操作で作成し、生成処理中には本番チェーンへ送信しない。

保管先の鍵を実行鍵から分離して送金済み売上を保護する。実行鍵が奪われた場合の残存許可内の不正引き落としを防ぐ保証はない。

## 設定と運用

「運営者のサブスク決済」「販売者のサブスク決済」「販売者の新規プラン作成」は独立して初期ONとする。決済OFFは該当販売主体の有効契約・利用期間・未完了の決済や許可取消が残る間は拒否する。新規プラン作成OFFでも販売者登録と既存プラン編集は継続できる。

送金先はチェーン別に設定する。設定不足を別チェーンの値で補わず、機能を自動OFFにしない。管理者には不足項目、購入者には受付不可を表示する。通知は既存アプリ内通知と有効なWeb Pushを使い、メールは追加しない。

返金は外部で手動実行し、金額・理由・チェーン・取引IDを記録する。購入者には該当explorerのリンクを表示し、「手動返金の記録」と明示する。自動照合・自動返金・利用期間の自動変更はしない。購入・販売契約や未完了処理があるUserの削除を拒否し、削除可能になった後も決済・返金履歴は保持する。

## 検証

2026-09-08の4チェーンの配置確認とfork実行結果は[billing-chain-verification.json](billing-chain-verification.json)に記録する。`test/chain/billing_fork_test.rb`は起動済みのlocalhost Anvilだけを受け付け、`web3_clientVersion`とchain IDを検証してから操作する。テスト用のUSDC発行と口座作成はfork内部で行う。Arbitrumは公開公式RPCで指定した過去状態を取得できなかったため、そのブロックを提供する公開dRPCを検証に使用した。アプリのRPCを自動切替する処理は持たない。

実行例は`BILLING_FORK_CHAIN_ID=8453 BILLING_FORK_PORT=18545 ruby -Itest test/chain/billing_fork_test.rb`。Anvilのfork先、chain ID、ブロック番号は記録と一致させる。Base Account SDKは公式`@base-org/account` 2.5.10のbrowser bundleを同梱し、vendorのLICENSEを保持する。

Tapioca標準のUrlHelpers compilerはホストのroute setだけを読むため、Billing専用compilerがEngineのroute setからcontroller用の型を生成する。RBIの手動編集やroute名の二重管理はしない。

契約・金額・並行実行・再送・確定待ち・解約競合・設定・権限をMinitestで検証する。公式USDC・Manager・Factoryの配置を4チェーンで確認し、forkで承認・引き落とし・分配・取消を検証する。RPC接続不可のまま4チェーン対応完了とは扱わない。

生成アプリの型検査、テスト、Docker buildと、全機能を有効にした日本語sampleのdesktop/mobile証跡を更新する。テスト・生成・撮影では本番資金を移動しない。
