---
number: 16
title: 生成アプリのUIをshadcn_view_componentsへ移行する
status: accepted
date: 2026-09-24
links:
- target: 6
  kind: amends
- target: 17
  kind: amendedby
---

# 生成アプリのUIをshadcn_view_componentsへ移行する

## Context and Problem Statement

生成アプリはdaisyUI 5のCSS plugin、theme token、コンポーネントclass、JavaScriptの状態切り替えに広く依存している。UIフレームワークを`shadcn_view_components`へ変更するには、依存関係の入れ替えだけでなく、各ViewのHTML構造と操作をgemの公開コンポーネントへ移す必要がある。

## Decision Drivers

* 生成アプリのUIを指定されたgemの公開APIで構成する
* Rails 8.1、Ruby 4.0、Tailwind CSS 4、ImportmapとStimulusを維持する
* コンポーネントの見た目と操作を生成アプリで検証する
* 旧daisyUI classを残して見た目だけを部分的に置き換えない

## Considered Options

* daisyUIを残して一部の画面だけgemのコンポーネントを使う
* `shadcn_view_components`を全構成で導入し、生成Viewとhelperをその公開APIへ移す

## Decision Outcome

`shadcn_view_components`を全構成のUI基盤とする。gemのinstall generatorでTailwind入力へEngine CSSを取り込み、`tw-animate-css`をnpmに追加し、Importmap経由でStimulus controllerを登録する。Viewとhelperは`Shadcn::*`の公開ViewComponentを使い、フォーム要素などRailsが生成するHTMLにはgemの公開class契約を適用する。daisyUI pluginとそのtheme、class、操作用JavaScriptを除去する。DESIGN.mdの色と文字組みはgemのsemantic token上で保持する。

### Consequences

* Good, because UIの構造、見た目、操作を一つのコンポーネント群へ揃えられる
* Good, because gem更新時のTailwind source探索はgem側が管理する
* Bad, because daisyUI固有のtabs、modal、pagination、engine上書きViewを構造ごと移行する必要がある
* Bad, because 既存のCSS class契約テストと画像証跡を全面的に更新する必要がある
* Bad, because 0.2.0のSorbet RBIは`**args`をHashとして扱い、公開キーワード引数の呼び出しを型エラーにする。生成アプリでは該当メソッドだけshim RBIでシグネチャを補正し、gem側の型定義が修正された版へ更新する際に削除を検討する

### Confirmation

最小構成と全部入り構成を生成し、Gem・npm依存、Tailwind build、Stimulus登録、全Viewの描画と操作、Minitest、型検査、desktop・mobileの証跡を検証する。生成元・生成済み`bootstrap.rb`・参照文書にdaisyUI導入処理と旧classが残らないことを確認する。

## More Information

導入手順と公開APIは`shadcn_view_components` 0.2.0の公開gemに同梱されたREADMEとinstall generatorを確認した。既存の対応バージョンと共通基盤は[ADR 6](0006-sheng-cheng-apurinoji-pan-ji-shu-todui-ying-baziyonwogu-ding-suru.md)を参照する。
