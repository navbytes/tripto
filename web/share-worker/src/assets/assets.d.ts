// Wrangler bundles *.jpg / *.png as binary "Data" modules (see the "rules"
// block in wrangler.jsonc); each import resolves to the file's bytes.
declare module "*.jpg" {
  const data: ArrayBuffer;
  export default data;
}
declare module "*.png" {
  const data: ArrayBuffer;
  export default data;
}
