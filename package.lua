  return {
    name = "LazyShpee/lastbin",
    version = "0.0.1",
    description = "Selfhosted Pastebin written in Lua",
    tags = { "pastebin", "hastebin", "self-hosted" },
    license = "MIT",
    author = { name = "LazyShpee", email = "comemureravaud@gmail.com" },
    homepage = "https://github.com/LazyShpee/lastbin",
    dependencies = {
      "SinisterRectus/sqlite3"
    },
    files = {
      "**.lua",
      "!test*"
    }
  }
  