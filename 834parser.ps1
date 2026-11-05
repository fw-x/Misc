#Requires -Version 7.0

if (-not ('Fast834Parser' -as [type])) {
    Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Threading.Tasks;

public sealed class Member834Record
{
    public string SourceFile { get; set; }
    public int MemberOrdinal { get; set; }
    public string LastName { get; set; }
    public string FirstName { get; set; }
    public string MemberId { get; set; }
    public string SSN { get; set; }
    public string DOB { get; set; }
    public string MatchedValue { get; set; }
    public string MatchType { get; set; }
}

public static class Fast834Parser
{
    public static List<Member834Record> ParseFiles(
        string[] filePaths,
        string[] targetIds,
        int maxDegreeOfParallelism)
    {
        if (filePaths == null)
        {
            throw new ArgumentNullException(nameof(filePaths));
        }

        if (targetIds == null)
        {
            throw new ArgumentNullException(nameof(targetIds));
        }

        var targetSet = new HashSet<string>(
            targetIds,
            StringComparer.OrdinalIgnoreCase);

        var resultBag = new ConcurrentBag<Member834Record>();

        var options = new ParallelOptions
        {
            MaxDegreeOfParallelism = Math.Max(
                1,
                Math.Min(maxDegreeOfParallelism, filePaths.Length))
        };

        Parallel.ForEach(
            filePaths,
            options,
            filePath =>
            {
                ParseSingleFile(
                    filePath,
                    targetSet,
                    resultBag);
            });

        var results = new List<Member834Record>(resultBag);

        results.Sort(
            delegate(Member834Record left, Member834Record right)
            {
                int fileComparison = StringComparer.OrdinalIgnoreCase.Compare(
                    left.SourceFile,
                    right.SourceFile);

                if (fileComparison != 0)
                {
                    return fileComparison;
                }

                return left.MemberOrdinal.CompareTo(
                    right.MemberOrdinal);
            });

        return results;
    }

    private static void ParseSingleFile(
        string filePath,
        HashSet<string> targetSet,
        ConcurrentBag<Member834Record> results)
    {
        string sourceFile = Path.GetFileName(filePath);

        int memberOrdinal = 0;

        string lastName = null;
        string firstName = null;
        string memberId = null;
        string ssn = null;
        string dob = null;

        bool hasCurrentMember = false;
        bool isMatched = false;

        string matchedValue = null;
        string matchType = null;

        // A relatively large read buffer reduces filesystem calls.
        const int readBufferSize = 1024 * 1024;

        // EDI segments are normally small, so this is only an initial size.
        var segmentBuilder = new StringBuilder(256);
        var readBuffer = new char[readBufferSize];

        using (var stream = new FileStream(
            filePath,
            FileMode.Open,
            FileAccess.Read,
            FileShare.Read,
            readBufferSize,
            FileOptions.SequentialScan))
        using (var reader = new StreamReader(
            stream,
            Encoding.UTF8,
            true,
            readBufferSize))
        {
            int charactersRead;

            while (
                (charactersRead = reader.Read(
                    readBuffer,
                    0,
                    readBuffer.Length)) > 0)
            {
                int segmentStart = 0;

                for (int index = 0; index < charactersRead; index++)
                {
                    if (readBuffer[index] != '~')
                    {
                        continue;
                    }

                    int characterCount = index - segmentStart;

                    if (characterCount > 0)
                    {
                        segmentBuilder.Append(
                            readBuffer,
                            segmentStart,
                            characterCount);
                    }

                    ProcessSegment(
                        segmentBuilder,
                        sourceFile,
                        targetSet,
                        results,
                        ref memberOrdinal,
                        ref hasCurrentMember,
                        ref lastName,
                        ref firstName,
                        ref memberId,
                        ref ssn,
                        ref dob,
                        ref isMatched,
                        ref matchedValue,
                        ref matchType);

                    segmentBuilder.Clear();
                    segmentStart = index + 1;
                }

                if (segmentStart < charactersRead)
                {
                    segmentBuilder.Append(
                        readBuffer,
                        segmentStart,
                        charactersRead - segmentStart);
                }
            }

            // Process a final segment if the file has no trailing "~".
            if (segmentBuilder.Length > 0)
            {
                ProcessSegment(
                    segmentBuilder,
                    sourceFile,
                    targetSet,
                    results,
                    ref memberOrdinal,
                    ref hasCurrentMember,
                    ref lastName,
                    ref firstName,
                    ref memberId,
                    ref ssn,
                    ref dob,
                    ref isMatched,
                    ref matchedValue,
                    ref matchType);
            }
        }

        // Save the final member in the file.
        SaveMemberIfMatched(
            sourceFile,
            memberOrdinal,
            hasCurrentMember,
            lastName,
            firstName,
            memberId,
            ssn,
            dob,
            isMatched,
            matchedValue,
            matchType,
            results);
    }

    private static void ProcessSegment(
        StringBuilder segmentBuilder,
        string sourceFile,
        HashSet<string> targetSet,
        ConcurrentBag<Member834Record> results,
        ref int memberOrdinal,
        ref bool hasCurrentMember,
        ref string lastName,
        ref string firstName,
        ref string memberId,
        ref string ssn,
        ref string dob,
        ref bool isMatched,
        ref string matchedValue,
        ref string matchType)
    {
        if (segmentBuilder.Length < 3)
        {
            return;
        }

        int first = 0;
        int last = segmentBuilder.Length - 1;

        // Remove line endings or spaces surrounding the segment.
        while (
            first <= last &&
            char.IsWhiteSpace(segmentBuilder[first]))
        {
            first++;
        }

        while (
            last >= first &&
            char.IsWhiteSpace(segmentBuilder[last]))
        {
            last--;
        }

        int length = last - first + 1;

        if (length < 3)
        {
            return;
        }

        char c0 = char.ToUpperInvariant(segmentBuilder[first]);
        char c1 = char.ToUpperInvariant(segmentBuilder[first + 1]);
        char c2 = char.ToUpperInvariant(segmentBuilder[first + 2]);

        // INS
        if (c0 == 'I' && c1 == 'N' && c2 == 'S')
        {
            SaveMemberIfMatched(
                sourceFile,
                memberOrdinal,
                hasCurrentMember,
                lastName,
                firstName,
                memberId,
                ssn,
                dob,
                isMatched,
                matchedValue,
                matchType,
                results);

            memberOrdinal++;
            hasCurrentMember = true;

            lastName = null;
            firstName = null;
            memberId = null;
            ssn = null;
            dob = null;

            isMatched = false;
            matchedValue = null;
            matchType = null;

            return;
        }

        if (!hasCurrentMember)
        {
            return;
        }

        // Ignore all irrelevant segments without creating a string.
        bool isNm1 = c0 == 'N' && c1 == 'M' && c2 == '1';
        bool isRef = c0 == 'R' && c1 == 'E' && c2 == 'F';
        bool isDmg = c0 == 'D' && c1 == 'M' && c2 == 'G';

        if (!isNm1 && !isRef && !isDmg)
        {
            return;
        }

        string segment = segmentBuilder
            .ToString(first, length)
            .Trim();

        string[] elements = segment.Split('*');

        if (isNm1)
        {
            if (elements.Length <= 1)
            {
                return;
            }

            string entityIdentifier = elements[1].Trim();

            if (
                !entityIdentifier.Equals(
                    "IL",
                    StringComparison.OrdinalIgnoreCase) &&
                !entityIdentifier.Equals(
                    "M8",
                    StringComparison.OrdinalIgnoreCase))
            {
                return;
            }

            if (elements.Length > 3)
            {
                lastName = Normalize(elements[3]);
            }

            if (elements.Length > 4)
            {
                firstName = Normalize(elements[4]);
            }

            // NM109
            if (elements.Length > 9)
            {
                string value = Normalize(elements[9]);

                if (value != null)
                {
                    memberId = value;

                    if (targetSet.Contains(value))
                    {
                        isMatched = true;

                        if (matchedValue == null)
                        {
                            matchedValue = value;
                            matchType = "NM109";
                        }
                    }
                }
            }

            return;
        }

        if (isRef)
        {
            if (elements.Length <= 2)
            {
                return;
            }

            string qualifier = elements[1].Trim();
            string value = Normalize(elements[2]);

            if (value == null)
            {
                return;
            }

            if (
                qualifier.Equals(
                    "0F",
                    StringComparison.OrdinalIgnoreCase) ||
                qualifier.Equals(
                    "1W",
                    StringComparison.OrdinalIgnoreCase))
            {
                memberId = value;

                if (targetSet.Contains(value))
                {
                    isMatched = true;

                    if (matchedValue == null)
                    {
                        matchedValue = value;
                        matchType = "REF*" + qualifier;
                    }
                }

                return;
            }

            if (
                qualifier.Equals(
                    "SY",
                    StringComparison.OrdinalIgnoreCase))
            {
                ssn = value;

                if (targetSet.Contains(value))
                {
                    isMatched = true;

                    if (matchedValue == null)
                    {
                        matchedValue = value;
                        matchType = "REF*SY";
                    }
                }
            }

            return;
        }

        // DMG
        if (elements.Length > 2)
        {
            dob = Normalize(elements[2]);
        }
    }

    private static void SaveMemberIfMatched(
        string sourceFile,
        int memberOrdinal,
        bool hasCurrentMember,
        string lastName,
        string firstName,
        string memberId,
        string ssn,
        string dob,
        bool isMatched,
        string matchedValue,
        string matchType,
        ConcurrentBag<Member834Record> results)
    {
        if (!hasCurrentMember || !isMatched)
        {
            return;
        }

        results.Add(
            new Member834Record
            {
                SourceFile = sourceFile,
                MemberOrdinal = memberOrdinal,
                LastName = lastName,
                FirstName = firstName,
                MemberId = memberId,
                SSN = ssn,
                DOB = dob,
                MatchedValue = matchedValue,
                MatchType = matchType
            });
    }

    private static string Normalize(string value)
    {
        if (value == null)
        {
            return null;
        }

        value = value.Trim();

        return value.Length == 0
            ? null
            : value;
    }
}
'@
}

function Get-834Members {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Pattern,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string[]]$TargetIds,

        [Parameter()]
        [ValidateRange(1, 32)]
        [int]$MaxFileThreads = 3,

        [Parameter()]
        [switch]$Recurse
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "Directory not found: $Path"
    }

    $targetList = [System.Collections.Generic.List[string]]::new()

    $targetSet = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )

    foreach ($targetId in $TargetIds) {
        if ($null -eq $targetId) {
            continue
        }

        $normalizedId = $targetId.Trim()

        if ($normalizedId.Length -eq 0) {
            continue
        }

        if ($targetSet.Add($normalizedId)) {
            $targetList.Add($normalizedId)
        }
    }

    if ($targetList.Count -eq 0) {
        Write-Warning 'No valid target IDs were provided.'
        return @()
    }

    $getChildItemParameters = @{
        LiteralPath = $Path
        Filter      = $Pattern
        File        = $true
        ErrorAction = 'Stop'
    }

    if ($Recurse) {
        $getChildItemParameters.Recurse = $true
    }

    $files = @(
        Get-ChildItem @getChildItemParameters |
            Sort-Object FullName
    )

    if ($files.Count -eq 0) {
        Write-Warning "No .edi files found in path: $Path"
        return @()
    }

    $filePaths = [string[]]$files.FullName

    # Never start more parser threads than there are files.
    $effectiveThreads = [Math]::Min($MaxFileThreads, $filePaths.Length)

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        $results = [Fast834Parser]::ParseFiles($filePaths, $targetList.ToArray(), $effectiveThreads)
    }
    finally {
        $stopwatch.Stop()
    }

    Write-Host (
        'Scanned {0} file(s) for {1:N0} target ID(s) in {2:N3} seconds. ' +
        'Found {3:N0} matching member record(s).' -f
        $filePaths.Length,
        $targetList.Count,
        $stopwatch.Elapsed.TotalSeconds,
        $results.Count
    ) -ForegroundColor Green

    return $results
}