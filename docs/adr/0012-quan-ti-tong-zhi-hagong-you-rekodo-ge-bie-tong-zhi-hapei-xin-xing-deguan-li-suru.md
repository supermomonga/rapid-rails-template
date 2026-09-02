---
number: 12
title: 全体通知は共有レコード、個別通知は配信行で管理する
status: accepted
date: 2026-09-02
---

# 全体通知は共有レコード、個別通知は配信行で管理する

## Context and Problem Statement

すべての利用者へ表示する通知を User ごとの配信行として保存すると、利用者数と通知数の積に比例して行が増え、通知後に登録した User へも別途同期が必要になる。一方、個別通知には受信者ごとの選択と既読状態が必要である。

## Decision Drivers

* 全体通知の保存量を User 数に比例させない
* 通知公開後に登録した User にも全体通知を表示する
* 個別通知の受信者と既読状態を明示的に保持する
* Web Push の購読・配信モデルとアプリ内通知を分離する

## Considered Options

* 全体通知にも User ごとの配信行を作成する
* 全体通知を共有し、User に最終確認位置を持たせる
* アプリ内通知と Web Push で同じ model・route を使う

## Decision Outcome

`Notification` が本文、公開条件、通知先を保持する。個別通知だけは `NotificationDelivery` が受信者と既読状態を持ち、差分同期で継続する配信の既読を維持する。全体通知は User ごとの配信行を作らず、User の最終確認日時を cursor として共有 `Notification` から取得する。Web Push は別の購読、route、service、job とする。

### Consequences

* Good, because 全体通知の保存量が User 数と通知数の積にならない
* Good, because 後から登録した User も公開中の全体通知を取得できる
* Good, because 個別通知では受信者ごとの既読状態を維持できる
* Bad, because 全体通知と個別通知で既読判定方式が異なる

### Confirmation

全体通知の `NotificationDelivery` が 0 件であること、後発 User への表示、cursor の単調更新、個別受信者の差分同期と既読維持、2種類の履歴と未読表示を model・request・system test と UI 証跡で確認する。

## More Information

現在の通知構成は[アーキテクチャ](../reference/architecture.md)と[採用技術とセットアップ要件](../reference/stack.md)を参照する。
