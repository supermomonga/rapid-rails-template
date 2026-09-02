---
number: 8
title: SQLite を用途別に分離し画像を Rails proxy と Thruster で配信する
status: accepted
date: 2026-09-02
---

# SQLite を用途別に分離し画像を Rails proxy と Thruster で配信する

## Context and Problem Statement

生成アプリは全環境で SQLite を使いながら、主データ、添付ファイル、queue、cache、cable の lifecycle と復旧対象を分ける必要がある。画像配信では、画像変換用の別 service を増やさず、warm request が Rails と SQLite へ到達しない構成が必要である。

## Decision Drivers

* 用途ごとに migration と運用上の責務を分離する
* Action Text と Profile 画像を全環境で同じ storage 契約にする
* 公開 signed URL を HTTP cache 可能にする
* 画像処理・配信用の外部 service を追加しない

## Considered Options

* 添付ファイルを disk service に保存する
* 独立した画像 proxy service を追加する
* Active Storage DB、libvips、Rails proxy route、Thruster を使う

## Decision Outcome

primary とは別の SQLite database に Active Storage の添付本体を保存し、必要に応じて queue、cache、cable も専用 database と migration path へ分離する。画像 variant は libvips で生成し、URL は Active Storage の proxy route に統一する。production の warm response は Thruster の HTTP cache から返す。

### Consequences

* Good, because 添付ファイルと各 Solid component の schema・運用責務を分離できる
* Good, because warm な画像 request は Puma、Rails、SQLite を迂回できる
* Bad, because database 数と migration path が増える
* Bad, because public signed URL と cache header の契約を維持する必要がある

### Confirmation

生成設定と migration の配置、全環境の storage database、variant 生成、proxy URL、Thruster cache の miss から hit への遷移をテストする。

## More Information

現在の database と画像配信契約は[採用技術とセットアップ要件](../reference/stack.md)を参照する。
