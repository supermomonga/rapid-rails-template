---
number: 13
title: Spend Permissions決済をアプリ内Engineと常設Solid Queueで構成する
status: accepted
date: 2026-09-08
links:
- target: 9
  kind: amends
- target: 14
  kind: amendedby
- target: 15
  kind: amendedby
---

# Spend Permissions決済をアプリ内Engineと常設Solid Queueで構成する

## Context and Problem Statement

運営者とアプリ内販売者の固定額サブスクを、四つのEVMチェーンで継続的に引き落とす。外部決済サーバーや独自コントラクトへ依存せず、生成アプリの認証、権限、画面、配備構成を再利用する必要がある。

## Decision Drivers

* 既存のSpendPermissionManagerと標準Smart Accountで承認・引き落とし・売上分配を構成する
* 通信断、ジョブの重複、チェーン再編成を支払成功と取り違えない
* 実行鍵と売上保管用の鍵を分離する
* 生成アプリの境界内で決済の責務を分離し、個別の有料機能の認可をホストに残す

## Considered Options

* ホストへ直接すべての決済コードを配置する
* 独立gemとして配布する
* アプリ内mountable Engineと常設Solid Queueを生成する
* 独自の売上分配コントラクトまたはCDP server-wallet APIを導入する

## Decision Outcome

アプリ内の`Billing::Engine`を常設し、Solid Queueを選択機能から必須基盤に変更する。Engineは契約、請求、支払許可、署名済み取引、返金記録、画面、ジョブを所有する。ホストのUser、認証、Action Policy、共通UI、通知と既存の1Password/Kamal運用を再利用する。Solid Cache、Solid Cable、運用画面の選択性は維持する。

Arbitrum、Base、Ethereum、PolygonのCircleネイティブUSDCを扱い、支払用Base Accountをログイン方法から分離する。既存Factoryで作った標準Smart Accountを集金口座とし、承認登録、引き落とし、販売者・運営者への分配を一括実行する。Rubyで署名し、送信前に取引とnonceを永続化する。チェーンの`finalized`を確認するまで支払確定としない。

### Consequences

* Engineを含む単一のbootstrap配布と、ホストの型検査・認証・UI証跡を一体で検証する必要がある。
* Queueを使わない生成構成は廃止する。同期処理や別adapterへのfallbackは追加しない。
* 確定待ちの時間は当初の契約周期に含まれる。遅延で更新日を動かさない。
* 売上は保管先へ即時分配するが、実行鍵の流出による残存許可内の不正引き落としは防げない。固定送金先を鍵の所有者に強制する独自コントラクトは作らない。
* 設定不足は明示的な利用不可として表示し、初期ONの機能設定を暗黙にOFFへ変えない。

### Confirmation

契約周期、猶予、二重請求防止、nonce競合、送信結果不明、finality、分配失敗時の全体取消、解約競合をテストする。4チェーンの配置コードとfork上での承認・引き落とし・取消を確認する。生成アプリの認証・権限・型検査・Docker・日本語desktop/mobile証跡も検証する。

## More Information

現在の仕様は[サブスク決済](../reference/billing.md)を正本とする。独立配布、対応チェーン追加、独自コントラクトによる実行権限制限が必要になった場合は、この境界を再評価する。

* [SpendPermissionManager](https://github.com/coinbase/spend-permissions/blob/main/src/SpendPermissionManager.sol)
* [CoinbaseSmartWallet](https://github.com/coinbase/smart-wallet/blob/main/src/CoinbaseSmartWallet.sol)
* [Circle USDC contracts](https://developers.circle.com/stablecoins/usdc-contract-addresses)
