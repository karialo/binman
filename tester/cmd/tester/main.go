package main
import (
  "flag"
  "fmt"
)
var version = "0.1.0"
func main() {
  flag.Parse()
  fmt.Printf("tester v%v — hello (go)\n", version)
}
