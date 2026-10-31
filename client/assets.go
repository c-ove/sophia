package main

import "embed"

//go:embed sophia-shell.sh bashrc all:zdotdir
var clientAssets embed.FS
