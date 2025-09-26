export function main() {
  console.log("JsApp v0.1.0 — hello (node)");
}
if (import.meta.url === `file://${process.argv[1]}`) main();
