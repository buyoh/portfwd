# PORTFWD

外部に露出できないホストサーバから外部に露出できるリモートサーバにSSHのリモートフォワーディング接続を作成し、リモートサーバからホストサーバへのアクセスを可能にするsystemdサービス。

## Usage

1. Copy `ssh` directory to `.ssh`
2. Update `.ssh/config` and `.ssh/id_rsa`, and more.
3. Run `install.sh`

## Run test

Run `test.rb`.

## ターミナル操作時の注意

ファイル削除を行うときは、`rm` `rmdir` コマンドではなく、`.trash/` ディレクトリに移動。
動作確認等のため一時ディレクトリ・ファイルが必要なときは、`/tmp`ではなく、カレントディレクトリの`./tmp` ディレクトリを使う。

## ディレクトリ構造

```
.
├── docs-ai : AI 向けのドキュメント
├── lib/ : アプリケーションコード(systemd での実行時に使う。インストール先にコピーする)
├── tools/ : セットアップ時に実行するコード(インストール先にコピーしない)。lib/ を参照してよいが、lib/ から tools/ は参照しない
├── ssh : 設定サンプル
├── install.sh
├── test.rb
└── 
```