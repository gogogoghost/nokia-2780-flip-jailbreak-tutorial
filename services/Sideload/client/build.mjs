// Bundles the codegen output of the Sideload service into `dist/service.js`.
//
// Run from the api-daemon checkout (`services/Sideload/client/`), where build.rs
// wrote `generated/sideload_service.js`. The bundle exposes the `lib_sideload`
// global and expects the `ExternalAPI` global, which applications load from
// http://127.0.0.1/api/v1/shared/core.js (like every other service client).
import { build } from 'esbuild'
import { mkdirSync } from 'node:fs'

const entry = process.env.SIDELOAD_CLIENT_ENTRY ?? 'generated/sideload_service.js'
const outfile = process.env.SIDELOAD_CLIENT_OUT ?? 'dist/service.js'

mkdirSync(outfile.replace(/\/[^/]*$/, ''), { recursive: true })

await build({
  entryPoints: [entry],
  bundle: true,
  format: 'iife',
  globalName: 'lib_sideload',
  target: ['firefox84'],
  outfile,
  legalComments: 'none',
  logLevel: 'info',
})
