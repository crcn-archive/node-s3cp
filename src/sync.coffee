walkr = require "walkr"
outcome = require "outcome"
step = require "stepc"
fs = require "fs"
async = require "async"
sift = require "sift"
winston = require "winston"
crypto = require "crypto"
path = require "path"
mkdirp = require "mkdirp"
hash = crypto.createHash "md5"
rmdir = require "rmdir"

mime = require "mime"

outcome.logAllErrors true

module.exports = class 

  ###
  ###

  constructor: (@s3cp, @options) ->
    @_s3 = s3cp._s3

    if not @options.limit
      @options.limit = 30

    if not @options.skip
      @options.skip = 0

    @validate = @options.validate


  ###
  ###

  start: (callback) ->

    o = outcome.e callback
    self = @


    step.async(
      (() ->
        self._scanLocalFiles @
      ),
      (() ->
        self._makeLocalManifest @
      ),
      (o.s () ->
        self._downloadManifest @
      ),
      (o.s () ->
        self._computeManifestDifference @
      ),
      callback
    )

  ###
  ###

  upload: (callback) ->
    self = @

    o = outcome.e (err) ->
      callback()

    step(
      (o.s () ->
        self._removeRemoteFiles @
      ),
      (o.s () ->
        self._uploadFiles @
      ),
      (() ->
        self._uploadManifest @
      ),
      callback
    )

  ###
  ###

  redownload: (callback) ->
    if fs.existsSync(@options.path)
      rmdir @options.path, () =>
        @download callback
    else
      @download callback

  ###
  ###

  download: (callback) ->
    o = outcome.e (err) ->
      callback()

    self = @


    step.async(
      (o.s () ->
        self._removeLocalFiles @
      ),
      (o.s () ->
        self._downloadFiles @
      ),
      () ->
        callback()
    )
    
  ###
  ###

  _removeLocalFiles: (callback) ->
    async.eachSeries @_remoteManifestDiff, ((file, next) ->

      o = outcome.e () ->
        next()

      step.async(
        (() ->
          fs.lstat file.lpath, @
        ),
        (o.s (stat) ->

          if stat.isDirectory()

            if file.exists
              return next()

            rmdir file.lpath, @
          else
            fs.unlink file.lpath, @
        ),
        () ->
          winston.info "local del #{file.rpath}"
          next()
      )

    ), callback

  ###
  ###

  _downloadFiles: (callback) ->
    async.eachLimit @_remoteManifestDiff, 1, ((file, next) =>
      return next() if file.dir
      self = @

      o = outcome.e () ->
        next()


      winston.info "s3 get #{file.rpath}"

      step.async(
        (() ->
          mkdirp path.dirname(file.lpath), @
        ),
        (() ->
          self._s3.getFile file.rpath.replace(/\s/g, "%20"), @
        ),
        (o.s (res) ->

          if res.statusCode isnt 200
            winston.error "s3 ERR get #{file.rpath} - statusCode=#{res.statusCode}"
            return next()

          stream = fs.createWriteStream(file.lpath, { flags: "w+" })
          res.pipe(stream)

          stream.on "close", @
          stream.on "error", (err) =>
            winston.error "s3 ERR get #{file.rpath} - errcode=#{err.code}"
            @()

        ),
        (() ->
          next()
        )
      )

    ), callback



  ###
   Downloads the manifest - desription of files that are currently on the server
  ###

  _downloadManifest: (callback) ->

    winston.info "s3 get #{@_manifestPath()}"

    o = outcome.e callback
    self = @
    self._remoteManifest = []
    step.async(
      (() ->
        self._s3.getFile self._manifestPath().replace(/\s/,"%20"), @
      ),
      (o.s (res) ->
        buffer = []
        if res.statusCode is 404 
          return @()

        next = @

        res.on "data", (chunk) ->
          buffer.push String chunk
        res.on "end", () ->
          try 
            self._remoteManifest = JSON.parse buffer.join ""
            self._remoteManifest.forEach (file) ->
              delete file.exists
          catch e

          next()
      ),
      callback
    )

  ###
  ###

  _computeManifestDifference: (callback) ->
    winston.silly "compare file diff"

    @_localManifestDiff  = @_diffManifest @_localManifest, @_remoteManifest
    @_remoteManifestDiff = @_diffManifest @_remoteManifest, @_localManifest

    return callback()

  ###
  ###

  _removeRemoteFiles: (callback) ->

    chunks = []
    chunkSize = 1000

    for i in [0..@_remoteManifestDiff.length] by chunkSize
      chunks.push @_remoteManifestDiff.slice(i, i + chunkSize).map (file) ->
        file.rpath


    async.eachSeries chunks, ((files, next) =>

      for file in files
        console.log "s3 del %s", file

      @_s3.deleteMultiple files, () ->
        next()

    ), callback

  ###
  ###

  _uploadFiles: (callback) ->
    winston.info "upload limit: #{@options.limit}"

    @_i = 0
    async.eachLimit @_localManifestDiff, @options.limit, @_uploadFile, callback

  ###
  ###

  _uploadFile: (file, next) =>
    return next() if file.dir
    tries = 10
    if (++@_i) < @options.skip
      return next()

    tryUploadingFile = () =>

      if not --tries
        return next()

      o = outcome.e (err) ->
        winston.error "s3 put #{file.rpath} ERR #{err.message}"
        tryUploadingFile()

      @_shouldReUploadFile file, o.s (shouldReUpload) =>

        if not shouldReUpload
          winston.info "##{@_i} s3 skip #{file.rpath}"
          return next()

        winston.info "##{@_i} s3 put #{file.rpath}"
        @_s3.putFile file.lpath, file.rpath.replace(/\s/g, "%20"), o.s next

    tryUploadingFile()

    

  ###
  ###

  _shouldReUploadFile: (file, next) ->
    o = outcome.e next
    self = @
    req = null

    if not @validate 
      return next null, true

    step.async(
      (() ->
        req = self._s3.getFile file.rpath.replace(/\s/g, "%20"), @
      ),
      ( o.s (res) ->

        req.abort()

        # file doesn't exist? 
        if res.statusCode isnt 200
          return @ null, true

        # the file might have been particually uploaded. Check the content length for that.
        @ null, file.size isnt Number res.headers['content-length']
      ),
      next
    )

  ###
  ###

  _diffManifest: (fromManifest, toManifest) ->
    fromManifest.filter (fromFile) =>
      found = false
      for toFile in toManifest

        # file found? check the modification date
        if toFile.rpath is fromFile.rpath
          found = true
          fromFile.exists = true
          return toFile.mtime < fromFile.mtime

      fromFile.exists = false


      # if it isn't found, then shove in the difffin
      return !found

  ###
  ###

  _scanLocalFiles: (callback) ->

    @_localFiles = []
    @_remoteFiles = []

    winston.info "local scan #{@options.path}"
    if not fs.existsSync(@options.path)
      return callback()

    realpath = fs.realpathSync @options.path

    walkr(@options.path).
    filter((file, next) =>
      file.destination = file.source.replace realpath, ""
      @_localFiles.push file
      next()
    ).start callback

  ###
  ###

  _makeLocalManifest: (callback) ->
    @_localManifest = @_localFiles.map (file) =>
      {
        rpath: @_dest(file.destination),
        lpath: file.source,
        mtime: new Date(file.stat.mtime).getTime(),
        ctime: new Date(file.stat.ctime).getTime(),
        size: file.stat.size,
        dir: file.stat.isDirectory()
      }

    callback()

  ###
  ###

  _uploadManifest: (callback) ->

    if not @_localManifestDiff.length and not @_remoteManifestDiff.length
      winston.info "no changes to local or remote manifest.json"
      return callback()

    winston.info "s3 put #{@_manifestPath()}"


    o = outcome.e callback
    self = @
    content = JSON.stringify @_localManifest
    chunks = []
    chunkSize = 1024 << 2

    for i in [0..content.length] by chunkSize
      chunks.push content.slice i, i + chunkSize


    step.async(
      (() ->
        req = self._s3.put self._manifestPath().replace(/\s/g,"%20"), { "Content-Length": content.length, "Content-Type": "json" }

        async.eachSeries chunks, ((chunk, next) ->
          req.write(chunk)
          setTimeout next, 20
        ), () =>
          req.end()
          @()
      ),
      callback
    )

  ###
  ###

  _dest: (path) -> ("#{@options.name}/#{path}").replace(/\\+/g, "").replace(/\/+/g, "/")

  ###
  ###

  _manifestPath: () -> @_dest "manifest.json"

