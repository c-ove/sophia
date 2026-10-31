package main

import "embed"

//go:embed athena-shell.sh bashrc all:zdotdir
var clientAssets embed.FS
