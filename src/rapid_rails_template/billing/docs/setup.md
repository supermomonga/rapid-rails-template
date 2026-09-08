# サブスク決済の設定

決済は初期ONですが、資格情報・送金先・集金口座・ガス代の設定がそろうまで受付できません。設定不足は`/admin/billing`に表示します。

## production・staging

各destinationの既存1Password vault内に、決済専用のitemを作成します。実行鍵は環境ごとに新規作成するか、その環境用の既存鍵を使用してください。同じ環境では4チェーンで共有します。実行鍵を売上保管先の鍵として使用しないでください。

次の5フィールドをCONCEALEDとして保存します。鍵の値をコマンド引数・Git・画面・ログへ書き出しません。

- `BILLING_EXECUTION_PRIVATE_KEY`: 32バイトのEthereum秘密鍵
- `BILLING_ARBITRUM_RPC_URL`: chain ID 42161のHTTPS RPC
- `BILLING_BASE_RPC_URL`: chain ID 8453のHTTPS RPC
- `BILLING_ETHEREUM_RPC_URL`: chain ID 1のHTTPS RPC
- `BILLING_POLYGON_RPC_URL`: chain ID 137のHTTPS RPC

`config/billing_secrets.production.yml`または`config/billing_secrets.staging.yml`に、資格情報の値ではなく参照先IDを保存します。`account_id`と`vault_id`は、そのdestinationのR2設定と同じ1Password account・vaultを使用します。

```yaml
account_id: ACCOUNT_ID
vault_id: DESTINATION_VAULT_ID
item_id: BILLING_ITEM_ID
```

その後、既存の`bin/rails deployment:configure`で既存destinationを選択し、既存のR2資格情報を使用してsecret参照を再生成します。生成する`.kamal/secrets.<destination>`はR2と決済の参照をそれぞれ取得し、Kamalのweb・workerへ同じ決済環境変数を渡します。このYAMLがないdestinationには決済用のsecret参照を追加しません。決済機能のON/OFF設定とは連動しません。

初回設定では、実行鍵のアドレスへ各チェーンのETH／POLを用意します。管理画面でチェーンごとに売上保管先とガス代見積上限を設定し、集金口座の作成を明示的に実行します。Factory、チェーンID、所有者、確定状態を検証してから受付可能になります。キーを差し替えた際に別の口座を自動作成することはありません。

## 開発と確認

開発用の同じ5環境変数は1Passwordからプロセスへ渡します。設定しなくてもアプリは起動し、決済受付不可を表示できます。テスト以外ではHTTPS RPCだけを使用します。テストはローカルAnvilの`127.0.0.1`に限ってHTTPを許可します。

RPCには`finalized`、履歴ブロックでの`eth_call`、EIP-1559のガス見積もり、署名済み取引の送信が必要です。Baseの見積もりはL1データ料金も含めます。公開RPCの履歴取得制限やレート制限は運用先の要件に合わせて確認してください。

本番の採掘済み取引は取り消せません。アプリ内の取引照合は`finalized`を待ちます。通信断では同じ取引を再送し、結果不明のまま別の引き落としを開始しません。送信開始前に解約した場合は、未使用nonceを自分宛てのゼロ額取引で消費し、元の引き落としは送信しません。この場合もガス代は運営者負担です。

返金は外部で実行し、管理画面へ手動記録します。記録した取引IDの自動照合は行いません。
