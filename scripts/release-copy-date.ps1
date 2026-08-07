function ConvertTo-UtcReleaseDate {
    param(
        [Parameter(Mandatory)]
        [object] $PublishedAt
    )

    $publishedAtUtc = if ($PublishedAt -is [DateTimeOffset]) {
        $PublishedAt.UtcDateTime
    } elseif ($PublishedAt -is [DateTime]) {
        if ($PublishedAt.Kind -eq [DateTimeKind]::Unspecified) {
            [DateTime]::SpecifyKind($PublishedAt, [DateTimeKind]::Utc)
        } else {
            $PublishedAt.ToUniversalTime()
        }
    } else {
        $styles = [System.Globalization.DateTimeStyles]::AllowWhiteSpaces -bor
            [System.Globalization.DateTimeStyles]::AssumeUniversal -bor
            [System.Globalization.DateTimeStyles]::AdjustToUniversal
        [DateTimeOffset]::Parse(
            [string] $PublishedAt,
            [System.Globalization.CultureInfo]::InvariantCulture,
            $styles
        ).UtcDateTime
    }

    return $publishedAtUtc.ToString(
        "yyyy-MM-dd",
        [System.Globalization.CultureInfo]::InvariantCulture
    )
}
