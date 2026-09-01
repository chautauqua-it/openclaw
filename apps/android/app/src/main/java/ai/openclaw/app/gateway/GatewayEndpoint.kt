package ai.openclaw.app.gateway

data class GatewayEndpoint(
  val stableId: String,
  val name: String,
  val host: String,
  val port: Int,
  val path: String? = null,
  val lanHost: String? = null,
  val tailnetDns: String? = null,
  val gatewayPort: Int? = null,
  val canvasPort: Int? = null,
  val tlsEnabled: Boolean = false,
  val tlsFingerprintSha256: String? = null,
) {
  companion object {
    fun manual(
      host: String,
      port: Int,
      path: String? = null,
    ): GatewayEndpoint =
      GatewayEndpoint(
        stableId = "manual|${host.lowercase()}|$port",
        name = "$host:$port",
        host = host,
        port = port,
        path = normalizeGatewayWsPath(path),
        tlsEnabled = false,
        tlsFingerprintSha256 = null,
      )
  }
}

/** Normalizes a gateway WebSocket path: null/blank/"/" become null, otherwise a leading "/" is ensured. */
fun normalizeGatewayWsPath(raw: String?): String? {
  var path = raw?.trim().orEmpty()
  if (path.isEmpty() || path == "/") return null
  if (!path.startsWith("/")) path = "/$path"
  return path
}

/** Splits a manual host input that may carry a path ("host/secret") into host and normalized path. */
fun splitGatewayHostInput(input: String): Pair<String, String?> {
  val trimmed = input.trim()
  val slash = trimmed.indexOf('/')
  if (slash < 0) return trimmed to null
  return trimmed.substring(0, slash).trim() to normalizeGatewayWsPath(trimmed.substring(slash))
}
