# 管理画面Overview 対応表

| 出典 | 目的 | 具体対象 | 役割 | 前後関係 | 候補語 | 初出定義 |
| --- | --- | --- | --- | --- | --- | --- |
| 承認済み要件 | 管理者が管理情報の入口を開けるようにする | `GET /admin`から表示する、IDを持たない単一の管理画面 | 目的 | 認証・認可 → 集計 → 表示 | Overview | Overviewとは、管理対象の現在値を一覧する単一の管理画面を指す。 |
| 承認済み要件 | 管理対象の現在値を把握できるようにする | 全ユーザー、管理者、直近30日の新規ユーザー、公開FAQ、管理対象ページの各件数 | 値 | 認証・認可 → 集計 → 表示 | 基本統計 | 基本統計とは、Overviewに常設する5種類の件数を指す。 |
| 既存のAction Policy境界 | 管理者以外のOverview利用を拒否する | 現在のUserがadmin roleを持つ場合だけ成立するOverview表示権限 | 手段 | 認証 → 認可 → 集計 | `UserPolicy#overview?` | `UserPolicy#overview?`とは、Overviewの表示可否を返すpolicy predicateを指す。 |
| 承認済み要件 | 管理者がaccount領域から管理領域へ移動できるようにする | account navigationと通常画面のheader dropdownにだけ追加する`/admin`への単一link | 手段 | 認可 → link表示 → Overview表示 | 管理画面link | 管理画面linkとは、管理者にだけ表示するaccount領域からOverviewへの遷移を指す。 |
| 既存のadmin navigation境界 | 管理領域内でOverviewの位置を示す | admin navigationの先頭に置き、`admin/overview`でactiveになるlink | 状態 | Overview表示 → active表示 | 概要menu | 概要menuとは、admin navigation内でOverviewを表す項目を指す。 |
