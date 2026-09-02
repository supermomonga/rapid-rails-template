---
number: 7
title: Passkey を常設し SIWE を追加認証方式にする
status: accepted
date: 2026-09-02
---

# Passkey を常設し SIWE を追加認証方式にする

## Context and Problem Statement

生成アプリは、ユーザー ID とパスワードを保存する認証ではなく、検証済み credential を使うパスワードレス認証を共通基盤にする。追加の EVM wallet 認証を選択しても、User、session、認可の境界を別系統に分けない必要がある。

## Decision Drivers

* discoverable credential によりユーザー ID 入力なしで認証する
* 複数 credential と紛失時の回復可能性を扱う
* challenge の replay、別 session 利用、削除対象自身による再認証を拒否する
* 追加認証も Devise の session と既存認可へ統合する

## Considered Options

* パスワード認証を常設する
* Passkey を常設し、SIWE を任意の追加方式にする
* Passkey と SIWE に別々の User・session 基盤を持たせる

## Decision Outcome

Devise 上に Passkey 認証を常設し、`additional_login_methods` で選択された場合だけ SIWE を追加する。WebAuthn と SIWE の challenge は purpose、User、browser session、期限、消費状態、必要な削除対象へ結び付け、transaction 内で一度だけ消費する。成功時は Devise の公開 `sign_in` API で同じ User session を確立する。

### Consequences

* Good, because 全構成が同じパスワードレス認証と認可境界を使う
* Good, because Passkey と wallet を複数登録し、操作単位の再認証に利用できる
* Bad, because WebAuthn 非対応環境では認証できない
* Bad, because challenge と credential の lifecycle を server-side で厳密に管理する必要がある

### Confirmation

signup、login、credential 追加・編集・解除、challenge の期限・replay・別 session、最後の credential 保護、SIWE 未登録 wallet の非開示境界を生成アプリのテストで確認する。

## More Information

現在の credential、challenge、画面契約は[採用技術とセットアップ要件](../reference/stack.md)と[対話オプションの定義方針](../reference/options.md)を参照する。
