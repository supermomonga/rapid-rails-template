---
number: 10
title: Kamal・Litestream・R2 で単一ホストの配備・保守・復旧を構成する
status: accepted
date: 2026-09-02
---

# Kamal・Litestream・R2 で単一ホストの配備・保守・復旧を構成する

## Context and Problem Statement

production でも SQLite を使う単一ホスト構成には、destination ごとの永続 volume、継続的な遠隔複製、資格情報管理、停止を伴う保守、確認付き復旧が必要である。通常の deploy、排他的な database 操作、Rails 内の一時的な 503 切り替えを混同しない構成にする必要がある。

## Decision Drivers

* production と staging のデータ・資格情報・host を分離する
* primary、storage、条件付き queue・cable を一組で複製・復旧する
* 破壊的操作に TTY、明示確認、deploy lock、rollback 用保存を要求する
* 外部状態の不一致を自動修復・上書きしない

## Considered Options

* Rails 標準の Docker/Kamal 生成物だけで運用する
* Kamal V2 に Litestream、Cloudflare R2、1Password、Vultr 設定を統合する
* 復旧や保守の失敗時に自動 rollback・自動修復する

## Decision Outcome

単一 Linux host・単一 Web replica を Kamal V2 で配備し、destination 別 volume の SQLite を Litestream Accessory から Cloudflare R2 へ複製する。資格情報は destination 別の 1Password vault と最小権限 token で管理し、server 設定は Vultr VPS の検証と SSH 強化に限定する。Rails 内のソフトメンテナンスと Rails 非依存のハードメンテナンスを分離し、手動復旧は dry-run、完全一致確認、全 DB 整合性検査、deploy lock、復旧前ファイル保存を必須にする。

### Consequences

* Good, because destination ごとの配備、複製、資格情報、復旧境界が明確になる
* Good, because 外部状態の不一致や破壊的操作が無確認で進まない
* Bad, because Kamal、Litestream、R2、1Password、Vultr の運用前提が増える
* Bad, because 複数 host や複数 Web replica は対象外になる

### Confirmation

生成された deployment 設定、destination 分離、資格情報の無変更事前調査、Litestream 起動時復元、maintenance state、復旧 plan・確認・整合性検査・rollback を contract test と smoke test で確認する。

## More Information

現在の topology、資格情報、maintenance、restore の契約は[採用技術とセットアップ要件](../reference/stack.md)を参照する。
