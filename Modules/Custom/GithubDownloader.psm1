class GithubDownloader {
    [string]$URL
    [string]$DownloaderRegex
    [string]$LatestVersion
    [string]$Filename

    GithubDownloader() { 
        $this.Init(@{}) 
    }

    GithubDownloader([string]$URL, [string]$DownloaderRegex) {
        $this.URL = $URL
        $this.DownloaderRegex = $DownloaderRegex
    }

    GithubDownloader([hashtable]$Properties) { 
        $this.Init($Properties) 
    }

    [void] Update() {
        $releaseEndpoint = "https://api.github.com/repos/$(($this.URL -replace "https://github.com/|/releases").trimEnd("/"))/releases"
        $releaseResponse = Invoke-RestMethod $releaseEndpoint
        $releaseLatest = ($releaseResponse | Sort-Object published_at -Descending)[0]
        $this.LatestVersion = $releaseLatest.tag_name
        $this.URL = ($releaseLatest[0].assets | Where-Object browser_download_url -match $this.DownloaderRegex).browser_download_url
        $this.Filename = ($this.URL -split "/")[-1]
    }
}