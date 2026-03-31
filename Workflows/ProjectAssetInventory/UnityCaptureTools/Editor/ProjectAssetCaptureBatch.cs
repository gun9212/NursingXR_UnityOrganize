using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Text;
using UnityEditor;
using UnityEngine;
using UnityEngine.Rendering;

public static class ProjectAssetCaptureBatch
{
    private const int DefaultPreviewSize = 1024;
    private const int PreviewLayer = 1;
    private static readonly Vector3 DefaultPreviewDirection = new Vector3(-0.78f, -2.10f, -0.92f).normalized;

    private enum PreviewMaterialMode
    {
        CompatiblePreview,
        OriginalFidelity
    }

    [Serializable]
    private sealed class CaptureRequest
    {
        public int captureSize = DefaultPreviewSize;
        public CaptureRequestEntry[] entries;
    }

    [Serializable]
    private sealed class CaptureRequestEntry
    {
        public string projectName;
        public string sourcePath;
        public string projectPath;
        public string capturePath;
        public string outputPath;
        public bool forceRecapture;
        public string issueType;
        public float previewDistanceScale;
        public string assetKind;
        public string topRoot;
        public string relativeFolder;
        public string fileName;
        public string extension;
    }

    private sealed class CaptureResultEntry
    {
        public string ProjectName;
        public string SourcePath;
        public string ProjectPath;
        public string CapturePath;
        public string outputPath;
        public bool forceRecapture;
        public string CaptureStatus;
        public string Error;
        public string AssetKind;
        public string TopRoot;
        public string RelativeFolder;
        public string FileName;
        public string Extension;
    }

    public static void RunBatchCapture()
    {
        var args = Environment.GetCommandLineArgs();
        var manifestArgument = GetCommandLineArgument(args, "-captureManifest");
        var resultArgument = GetCommandLineArgument(args, "-captureResult");
        var sizeArgument = GetCommandLineArgument(args, "-captureSize");

        if (string.IsNullOrWhiteSpace(manifestArgument))
        {
            throw new InvalidOperationException("Missing -captureManifest.");
        }

        if (string.IsNullOrWhiteSpace(resultArgument))
        {
            throw new InvalidOperationException("Missing -captureResult.");
        }

        var manifestPath = Path.GetFullPath(manifestArgument.Trim());
        if (!File.Exists(manifestPath))
        {
            throw new FileNotFoundException("Capture manifest was not found.", manifestPath);
        }

        var requestJson = File.ReadAllText(manifestPath, new UTF8Encoding(false));
        var request = JsonUtility.FromJson<CaptureRequest>(requestJson);
        if (request == null)
        {
            throw new InvalidOperationException("Could not parse capture manifest JSON.");
        }

        var previewSize = ParsePreviewSize(sizeArgument, request.captureSize);
        var resultPath = Path.GetFullPath(resultArgument.Trim());
        Directory.CreateDirectory(Path.GetDirectoryName(resultPath) ?? Directory.GetParent(Application.dataPath).FullName);

        var results = new List<CaptureResultEntry>();
        var entries = request.entries ?? Array.Empty<CaptureRequestEntry>();
        AssetPreview.SetPreviewTextureCacheSize(Math.Max(256, entries.Length * 4));

        foreach (var entry in entries)
        {
            if (entry == null)
            {
                continue;
            }

            var resultEntry = new CaptureResultEntry
            {
                ProjectName = entry.projectName ?? string.Empty,
                SourcePath = NormalizePath(entry.sourcePath),
                ProjectPath = NormalizePath(entry.projectPath),
                CapturePath = NormalizePath(entry.capturePath),
                CaptureStatus = "failed",
                Error = string.Empty,
                AssetKind = entry.assetKind ?? string.Empty,
                TopRoot = entry.topRoot ?? string.Empty,
                RelativeFolder = entry.relativeFolder ?? string.Empty,
                FileName = entry.fileName ?? string.Empty,
                Extension = (entry.extension ?? string.Empty).ToLowerInvariant()
            };

            var absoluteOutputPath = ResolveOutputPath(entry.outputPath);
            var issueType = (entry.issueType ?? string.Empty).Trim();
            var disableAssetPreviewFallback =
                string.Equals(issueType, "placeholder_duplicate", StringComparison.OrdinalIgnoreCase) ||
                string.Equals(issueType, "blank_or_tiny_subject", StringComparison.OrdinalIgnoreCase);
            var previewDistanceScale = entry.previewDistanceScale > 0f
                ? entry.previewDistanceScale
                : (string.Equals(issueType, "blank_or_tiny_subject", StringComparison.OrdinalIgnoreCase) ? 0.55f : 1f);

            try
            {
                if (!entry.forceRecapture && File.Exists(absoluteOutputPath))
                {
                    resultEntry.CaptureStatus = "success";
                    results.Add(resultEntry);
                    continue;
                }

                if (string.IsNullOrWhiteSpace(resultEntry.SourcePath))
                {
                    throw new InvalidOperationException("sourcePath was empty.");
                }

                var modelAsset = AssetDatabase.LoadAssetAtPath<GameObject>(resultEntry.SourcePath);
                if (modelAsset == null)
                {
                    throw new InvalidOperationException("AssetDatabase.LoadAssetAtPath<GameObject> returned null.");
                }

                var preview = RenderModelPreview(
                    resultEntry.SourcePath,
                    modelAsset,
                    previewSize,
                    previewSize,
                    PreviewMaterialMode.CompatiblePreview,
                    30f,
                    previewDistanceScale,
                    issueType,
                    !disableAssetPreviewFallback,
                    out var failureReason);
                if (preview == null)
                {
                    throw new InvalidOperationException(string.IsNullOrWhiteSpace(failureReason) ? "Preview render returned null." : failureReason);
                }

                Directory.CreateDirectory(Path.GetDirectoryName(absoluteOutputPath) ?? Directory.GetParent(Application.dataPath).FullName);
                var readablePreview = CreateReadableTexture(preview, previewSize, previewSize);
                try
                {
                    File.WriteAllBytes(absoluteOutputPath, readablePreview.EncodeToPNG());
                }
                finally
                {
                    UnityEngine.Object.DestroyImmediate(readablePreview);
                    UnityEngine.Object.DestroyImmediate(preview);
                }

                resultEntry.CaptureStatus = "success";
            }
            catch (Exception exception)
            {
                resultEntry.CaptureStatus = "failed";
                resultEntry.Error = exception.Message;
            }

            results.Add(resultEntry);
        }

        WriteCaptureInventory(resultPath, results);
        Debug.Log(BuildSummary(entries.Length, previewSize, resultPath, results));
    }

    private static void WriteCaptureInventory(string path, IEnumerable<CaptureResultEntry> results)
    {
        var builder = new StringBuilder();
        builder.AppendLine("project_name,source_path,project_path,capture_path,capture_status,error,asset_kind,top_root,relative_folder,file_name,extension");
        foreach (var result in results)
        {
            builder.AppendLine(string.Join(",",
                EscapeCsvValue(result.ProjectName),
                EscapeCsvValue(result.SourcePath),
                EscapeCsvValue(result.ProjectPath),
                EscapeCsvValue(result.CapturePath),
                EscapeCsvValue(result.CaptureStatus),
                EscapeCsvValue(result.Error),
                EscapeCsvValue(result.AssetKind),
                EscapeCsvValue(result.TopRoot),
                EscapeCsvValue(result.RelativeFolder),
                EscapeCsvValue(result.FileName),
                EscapeCsvValue(result.Extension)));
        }

        File.WriteAllText(path, builder.ToString(), new UTF8Encoding(false));
    }

    private static string BuildSummary(int requestedCount, int previewSize, string resultPath, List<CaptureResultEntry> results)
    {
        var builder = new StringBuilder();
        builder.AppendLine("Project Asset Capture Summary");
        builder.AppendLine("- Requested Assets: " + requestedCount);
        builder.AppendLine("- Result Rows: " + results.Count);
        builder.AppendLine("- Preview Size: " + previewSize);
        builder.AppendLine("- Result CSV: " + resultPath);
        builder.AppendLine("- Success: " + results.Count(entry => entry.CaptureStatus == "success"));
        builder.AppendLine("- Failed: " + results.Count(entry => entry.CaptureStatus == "failed"));
        return builder.ToString().TrimEnd();
    }

    private static Texture2D TryRenderWithAssetPreview(UnityEngine.Object asset, int width, int height)
    {
        if (asset == null)
        {
            return null;
        }

        var instanceId = asset.GetInstanceID();
        for (var attempt = 0; attempt < 120; attempt++)
        {
            var preview = AssetPreview.GetAssetPreview(asset);
            if (preview != null)
            {
                return CreateReadableTexture(preview, width, height);
            }

            if (!AssetPreview.IsLoadingAssetPreview(instanceId))
            {
                break;
            }

            System.Threading.Thread.Sleep(25);
        }

        var miniThumbnail = AssetPreview.GetMiniThumbnail(asset);
        return miniThumbnail != null ? CreateReadableTexture(miniThumbnail, width, height) : null;
    }

    private static Texture2D CreateReadableTexture(Texture sourceTexture, int width, int height)
    {
        var renderTexture = RenderTexture.GetTemporary(width, height, 0, RenderTextureFormat.ARGB32);
        var previousActive = RenderTexture.active;
        Graphics.Blit(sourceTexture, renderTexture);

        RenderTexture.active = renderTexture;
        var readableTexture = new Texture2D(width, height, TextureFormat.RGBA32, false)
        {
            hideFlags = HideFlags.HideAndDontSave
        };
        readableTexture.ReadPixels(new Rect(0f, 0f, width, height), 0, 0);
        readableTexture.Apply(false, false);

        RenderTexture.active = previousActive;
        RenderTexture.ReleaseTemporary(renderTexture);
        return readableTexture;
    }

    private static Texture2D RenderModelPreview(
        string assetPath,
        GameObject modelAsset,
        int width,
        int height,
        PreviewMaterialMode materialMode,
        float previewFieldOfView,
        float previewDistanceScale,
        string issueType,
        bool allowAssetPreviewFallback,
        out string failureReason)
    {
        failureReason = string.Empty;
        GameObject instance = null;
        var loadedPrefabContents = false;
        PreviewRenderUtility previewUtility = null;

        try
        {
            var assetExtension = Path.GetExtension(assetPath);
            if (string.Equals(assetExtension, ".prefab", StringComparison.OrdinalIgnoreCase))
            {
                instance = TryLoadPrefabContents(assetPath, out failureReason);
                loadedPrefabContents = instance != null;
                if (instance == null)
                {
                    var prefabInstantiateFailureReason = string.Empty;
                    instance = TryInstantiatePrefabAsset(modelAsset, out prefabInstantiateFailureReason);
                    loadedPrefabContents = false;
                    if (instance == null && !string.IsNullOrWhiteSpace(prefabInstantiateFailureReason))
                    {
                        failureReason = string.IsNullOrWhiteSpace(failureReason)
                            ? prefabInstantiateFailureReason
                            : failureReason + " | " + prefabInstantiateFailureReason;
                    }
                }

                if (instance == null)
                {
                    if (allowAssetPreviewFallback)
                    {
                        var prefabPreview = TryRenderWithAssetPreview(modelAsset, width, height);
                        if (prefabPreview != null)
                        {
                            return prefabPreview;
                        }
                    }

                    failureReason = string.IsNullOrWhiteSpace(failureReason)
                        ? "prefab preview could not be generated safely"
                        : failureReason;
                    return null;
                }
            }
            else
            {
                instance = UnityEngine.Object.Instantiate(modelAsset);
                instance.hideFlags = HideFlags.HideAndDontSave;
            }

            SetLayerRecursively(instance, PreviewLayer);
            instance.transform.position = Vector3.zero;
            instance.transform.rotation = Quaternion.identity;
            instance.transform.localScale = Vector3.one;

            var clip = GetPrimaryAnimationClip(assetPath);
            if (clip != null && clip.length > 0f)
            {
                var sampleTime = Mathf.Clamp(clip.length * 0.35f, 0f, clip.length);
                clip.SampleAnimation(instance, sampleTime);
            }

            var renderers = instance.GetComponentsInChildren<Renderer>(true);
            if (renderers.Length == 0)
            {
                if (allowAssetPreviewFallback)
                {
                    var previewFromAssetPreview = TryRenderWithAssetPreview(modelAsset, width, height);
                    if (previewFromAssetPreview != null)
                    {
                        return previewFromAssetPreview;
                    }
                }

                failureReason = "no renderers found in model";
                return null;
            }
            if (materialMode == PreviewMaterialMode.CompatiblePreview)
            {
                PrepareRendererMaterialsForPreview(renderers);
            }

            var bounds = CalculateCombinedBounds(renderers);
            if (bounds.size == Vector3.zero)
            {
                failureReason = "renderer bounds are empty";
                return null;
            }

            previewUtility = new PreviewRenderUtility();
            previewUtility.camera.clearFlags = CameraClearFlags.SolidColor;
            previewUtility.camera.backgroundColor = new Color(0.19f, 0.19f, 0.19f, 0f);
            previewUtility.camera.renderingPath = RenderingPath.Forward;
            previewUtility.camera.useOcclusionCulling = false;
            previewUtility.camera.fieldOfView = previewFieldOfView;
            previewUtility.camera.aspect = Mathf.Max(0.01f, (float)width / height);

            previewUtility.lights[0].intensity = 1.1f;
            previewUtility.lights[0].color = new Color(0.95f, 0.95f, 0.98f, 1f);
            previewUtility.lights[0].transform.rotation = Quaternion.Euler(35f, 35f, 0f);
            previewUtility.lights[1].intensity = 0.8f;
            previewUtility.lights[1].color = new Color(0.78f, 0.8f, 0.85f, 1f);
            previewUtility.lights[1].transform.rotation = Quaternion.Euler(340f, 218f, 177f);
            previewUtility.ambientColor = new Color(0.42f, 0.42f, 0.44f, 1f);

            previewUtility.AddSingleGO(instance);

            var previewTexture = string.Equals(issueType, "blank_or_tiny_subject", StringComparison.OrdinalIgnoreCase)
                ? RenderTinySubjectPreview(previewUtility, bounds, width, height, previewDistanceScale)
                : RenderStaticPreview(previewUtility, bounds, width, height, previewDistanceScale);
            if (previewTexture == null)
            {
                failureReason = "PreviewRenderUtility returned no texture";
                return null;
            }

            return previewTexture;
        }
        catch (Exception exception)
        {
            failureReason = exception.Message;
            return null;
        }
        finally
        {
            if (previewUtility != null)
            {
                previewUtility.Cleanup();
            }

            if (instance != null)
            {
                if (loadedPrefabContents)
                {
                    PrefabUtility.UnloadPrefabContents(instance);
                }
                else
                {
                    UnityEngine.Object.DestroyImmediate(instance);
                }
            }
        }
    }

    private static GameObject TryInstantiatePrefabAsset(GameObject prefabAsset, out string failureReason)
    {
        failureReason = string.Empty;
        if (prefabAsset == null)
        {
            failureReason = "prefab asset was null";
            return null;
        }

        try
        {
            var instance = PrefabUtility.InstantiatePrefab(prefabAsset) as GameObject;
            if (instance == null)
            {
                instance = UnityEngine.Object.Instantiate(prefabAsset);
            }

            if (instance == null)
            {
                failureReason = "Prefab instantiate returned null";
                return null;
            }

            instance.hideFlags = HideFlags.HideAndDontSave;
            return instance;
        }
        catch (Exception exception)
        {
            failureReason = exception.Message;
            return null;
        }
    }

    private static GameObject TryLoadPrefabContents(string assetPath, out string failureReason)
    {
        failureReason = string.Empty;

        try
        {
            var prefabRoot = PrefabUtility.LoadPrefabContents(assetPath);
            if (prefabRoot == null)
            {
                failureReason = "PrefabUtility.LoadPrefabContents returned null";
                return null;
            }

            prefabRoot.hideFlags = HideFlags.HideAndDontSave;
            return prefabRoot;
        }
        catch (Exception exception)
        {
            failureReason = exception.Message;
            return null;
        }
    }

    private static void PrepareRendererMaterialsForPreview(IEnumerable<Renderer> renderers)
    {
        foreach (var renderer in renderers)
        {
            var sourceMaterials = renderer.sharedMaterials;
            if (sourceMaterials == null || sourceMaterials.Length == 0)
            {
                continue;
            }

            var previewMaterials = new Material[sourceMaterials.Length];
            for (var index = 0; index < sourceMaterials.Length; index++)
            {
                previewMaterials[index] = CreateCompatiblePreviewMaterial(sourceMaterials[index]);
            }

            renderer.sharedMaterials = previewMaterials;
        }
    }

    private static Material CreateCompatiblePreviewMaterial(Material sourceMaterial)
    {
        var usesScriptableRenderPipeline = GraphicsSettings.currentRenderPipeline != null;
        var fallbackShader = usesScriptableRenderPipeline
            ? Shader.Find("Universal Render Pipeline/Lit")
            : null;

        fallbackShader = fallbackShader ?? Shader.Find("Standard") ?? Shader.Find("Unlit/Texture") ?? Shader.Find("Sprites/Default");
        if (fallbackShader == null)
        {
            throw new InvalidOperationException("No supported preview shader was found.");
        }

        var targetMaterial = new Material(fallbackShader)
        {
            hideFlags = HideFlags.HideAndDontSave
        };

        if (sourceMaterial == null)
        {
            return targetMaterial;
        }

        // Unity 6 projects in this workspace have shown native crashes inside Material.HasProperty
        // during preview-material cloning, so keep a neutral fallback material there instead.
        if (Application.unityVersion.StartsWith("6000.", StringComparison.Ordinal))
        {
            return targetMaterial;
        }

        CopyColorProperty(sourceMaterial, targetMaterial, "_BaseColor", "_BaseColor");
        CopyColorProperty(sourceMaterial, targetMaterial, "_Color", "_BaseColor");
        CopyColorProperty(sourceMaterial, targetMaterial, "_Color", "_Color");
        CopyColorProperty(sourceMaterial, targetMaterial, "_EmissionColor", "_EmissionColor");

        CopyTextureProperty(sourceMaterial, targetMaterial, "_BaseMap", "_BaseMap");
        CopyTextureProperty(sourceMaterial, targetMaterial, "_BaseMap", "_MainTex");
        CopyTextureProperty(sourceMaterial, targetMaterial, "_MainTex", "_MainTex");
        CopyTextureProperty(sourceMaterial, targetMaterial, "_BumpMap", "_BumpMap");
        CopyTextureProperty(sourceMaterial, targetMaterial, "_NormalMap", "_BumpMap");
        CopyTextureProperty(sourceMaterial, targetMaterial, "_MetallicGlossMap", "_MetallicGlossMap");
        CopyTextureProperty(sourceMaterial, targetMaterial, "_EmissionMap", "_EmissionMap");
        CopyTextureProperty(sourceMaterial, targetMaterial, "_OcclusionMap", "_OcclusionMap");

        CopyFloatProperty(sourceMaterial, targetMaterial, "_Metallic", "_Metallic");
        CopyFloatProperty(sourceMaterial, targetMaterial, "_Glossiness", "_Smoothness");
        CopyFloatProperty(sourceMaterial, targetMaterial, "_Smoothness", "_Smoothness");
        CopyFloatProperty(sourceMaterial, targetMaterial, "_Cutoff", "_Cutoff");

        if (targetMaterial.HasProperty("_Surface"))
        {
            var isTransparent = sourceMaterial.renderQueue >= (int)RenderQueue.Transparent;
            targetMaterial.SetFloat("_Surface", isTransparent ? 1f : 0f);
            targetMaterial.renderQueue = isTransparent ? (int)RenderQueue.Transparent : -1;
        }

        if (targetMaterial.HasProperty("_AlphaClip"))
        {
            var cutoff = targetMaterial.HasProperty("_Cutoff") ? targetMaterial.GetFloat("_Cutoff") : 0f;
            targetMaterial.SetFloat("_AlphaClip", cutoff > 0.0001f ? 1f : 0f);
        }

        return targetMaterial;
    }

    private static void CopyColorProperty(Material sourceMaterial, Material targetMaterial, string sourceProperty, string targetProperty)
    {
        if (!sourceMaterial.HasProperty(sourceProperty) || !targetMaterial.HasProperty(targetProperty))
        {
            return;
        }

        targetMaterial.SetColor(targetProperty, sourceMaterial.GetColor(sourceProperty));
    }

    private static void CopyFloatProperty(Material sourceMaterial, Material targetMaterial, string sourceProperty, string targetProperty)
    {
        if (!sourceMaterial.HasProperty(sourceProperty) || !targetMaterial.HasProperty(targetProperty))
        {
            return;
        }

        targetMaterial.SetFloat(targetProperty, sourceMaterial.GetFloat(sourceProperty));
    }

    private static void CopyTextureProperty(Material sourceMaterial, Material targetMaterial, string sourceProperty, string targetProperty)
    {
        if (!sourceMaterial.HasProperty(sourceProperty) || !targetMaterial.HasProperty(targetProperty))
        {
            return;
        }

        var texture = sourceMaterial.GetTexture(sourceProperty);
        if (texture == null)
        {
            return;
        }

        targetMaterial.SetTexture(targetProperty, texture);
        targetMaterial.SetTextureScale(targetProperty, sourceMaterial.GetTextureScale(sourceProperty));
        targetMaterial.SetTextureOffset(targetProperty, sourceMaterial.GetTextureOffset(sourceProperty));

        if ((targetProperty == "_BumpMap" || targetProperty == "_NormalMap") && targetMaterial.HasProperty("_BumpScale"))
        {
            var bumpScale = sourceMaterial.HasProperty("_BumpScale") ? sourceMaterial.GetFloat("_BumpScale") : 1f;
            targetMaterial.SetFloat("_BumpScale", bumpScale);
        }
    }

    private static Texture2D CopyTexture(Texture2D sourceTexture)
    {
        var copiedTexture = new Texture2D(sourceTexture.width, sourceTexture.height, TextureFormat.RGBA32, false)
        {
            hideFlags = HideFlags.HideAndDontSave,
            name = sourceTexture.name + "_Copy"
        };

        copiedTexture.SetPixels(sourceTexture.GetPixels());
        copiedTexture.Apply(false, false);
        return copiedTexture;
    }

    private static Texture2D RenderStaticPreview(PreviewRenderUtility previewUtility, Bounds bounds, int width, int height, float distanceScale)
    {
        return RenderCompositionAwarePreview(previewUtility, bounds, width, height, distanceScale);
    }

    private static Texture2D RenderCompositionAwarePreview(PreviewRenderUtility previewUtility, Bounds bounds, int width, int height, float baseDistanceScale)
    {
        var normalizedBaseScale = Mathf.Clamp(baseDistanceScale > 0f ? baseDistanceScale : 1f, 0.05f, 4f);
        var backgroundColor = previewUtility.camera.backgroundColor;

        FramePreviewCamera(previewUtility.camera, bounds, normalizedBaseScale);
        var bestTexture = RenderStaticPreviewTexture(previewUtility, width, height);
        if (bestTexture == null)
        {
            return null;
        }

        var bestScore = ScoreCompositionCandidate(bestTexture, backgroundColor, out var requiresRetry);
        if (!requiresRetry)
        {
            return bestTexture;
        }

        var candidateDirections = new[]
        {
            DefaultPreviewDirection,
            new Vector3(-0.62f, -2.35f, -0.70f).normalized,
            new Vector3(-1.05f, -1.95f, -1.15f).normalized,
            new Vector3(0.48f, -2.00f, -0.82f).normalized
        };
        var candidateScales = new[]
        {
            Mathf.Clamp(normalizedBaseScale * 1.15f, 0.05f, 4f),
            Mathf.Clamp(normalizedBaseScale * 1.35f, 0.05f, 4f),
            Mathf.Clamp(normalizedBaseScale * 1.55f, 0.05f, 4f)
        }
            .Distinct()
            .ToArray();

        foreach (var direction in candidateDirections)
        {
            foreach (var scale in candidateScales)
            {
                if (Vector3.Dot(direction, DefaultPreviewDirection) > 0.999f && Mathf.Abs(scale - normalizedBaseScale) < 0.0001f)
                {
                    continue;
                }

                FramePreviewCamera(previewUtility.camera, bounds, scale, direction);
                var candidateTexture = RenderStaticPreviewTexture(previewUtility, width, height);
                if (candidateTexture == null)
                {
                    continue;
                }

                var candidateScore = ScoreCompositionCandidate(candidateTexture, backgroundColor, out var candidateRequiresRetry);
                if (candidateScore > bestScore)
                {
                    UnityEngine.Object.DestroyImmediate(bestTexture);
                    bestTexture = candidateTexture;
                    bestScore = candidateScore;
                    if (!candidateRequiresRetry)
                    {
                        return bestTexture;
                    }
                }
                else
                {
                    UnityEngine.Object.DestroyImmediate(candidateTexture);
                }
            }
        }

        return bestTexture;
    }

    private static Texture2D RenderTinySubjectPreview(PreviewRenderUtility previewUtility, Bounds bounds, int width, int height, float baseDistanceScale)
    {
        var normalizedBaseScale = Mathf.Clamp(baseDistanceScale > 0f ? baseDistanceScale : 0.12f, 0.0005f, 4f);
        var candidateScales = new[]
        {
            normalizedBaseScale,
            Mathf.Clamp(normalizedBaseScale * 0.5f, 0.0005f, 4f),
            Mathf.Clamp(normalizedBaseScale * 0.25f, 0.0005f, 4f),
            Mathf.Clamp(normalizedBaseScale * 2f, 0.0005f, 4f),
            Mathf.Clamp(normalizedBaseScale * 4f, 0.0005f, 4f)
        }
            .Distinct()
            .ToArray();

        Texture2D bestTexture = null;
        var bestScore = float.NegativeInfinity;
        var backgroundColor = previewUtility.camera.backgroundColor;

        foreach (var scale in candidateScales)
        {
            FramePreviewCamera(previewUtility.camera, bounds, scale);
            var candidateTexture = RenderStaticPreviewTexture(previewUtility, width, height);
            if (candidateTexture == null)
            {
                continue;
            }

            var analyzedTexture = TryCropAndUpscaleForeground(candidateTexture, backgroundColor, out var foregroundRatio, out var croppedForegroundRatio);
            var score = Mathf.Max(foregroundRatio, croppedForegroundRatio * 1.5f);
            if (score > bestScore)
            {
                if (bestTexture != null)
                {
                    UnityEngine.Object.DestroyImmediate(bestTexture);
                }

                bestTexture = analyzedTexture;
                bestScore = score;
                if (bestScore >= 0.02f)
                {
                    break;
                }

                continue;
            }

            UnityEngine.Object.DestroyImmediate(analyzedTexture);
        }

        return bestTexture;
    }

    private static Texture2D RenderStaticPreviewTexture(PreviewRenderUtility previewUtility, int width, int height)
    {
        previewUtility.BeginStaticPreview(new Rect(0f, 0f, width, height));
        RenderPreviewUtility(previewUtility);

        var previewTexture = previewUtility.EndStaticPreview();
        return previewTexture != null ? CopyTexture(previewTexture) : null;
    }

    private static Texture2D TryCropAndUpscaleForeground(Texture2D texture, Color backgroundColor, out float foregroundRatio, out float croppedForegroundRatio)
    {
        foregroundRatio = CalculateForegroundRatio(texture, backgroundColor, out var minX, out var minY, out var maxX, out var maxY);
        croppedForegroundRatio = foregroundRatio;
        if (foregroundRatio <= 0f || maxX < minX || maxY < minY)
        {
            return texture;
        }

        var marginX = Mathf.Max(6, Mathf.RoundToInt((maxX - minX + 1) * 0.35f));
        var marginY = Mathf.Max(6, Mathf.RoundToInt((maxY - minY + 1) * 0.35f));
        minX = Mathf.Max(0, minX - marginX);
        minY = Mathf.Max(0, minY - marginY);
        maxX = Mathf.Min(texture.width - 1, maxX + marginX);
        maxY = Mathf.Min(texture.height - 1, maxY + marginY);

        var cropWidth = Mathf.Max(1, maxX - minX + 1);
        var cropHeight = Mathf.Max(1, maxY - minY + 1);
        var croppedTexture = new Texture2D(cropWidth, cropHeight, TextureFormat.RGBA32, false)
        {
            hideFlags = HideFlags.HideAndDontSave
        };
        croppedTexture.SetPixels(texture.GetPixels(minX, minY, cropWidth, cropHeight));
        croppedTexture.Apply(false, false);

        var upscaledTexture = CreateReadableTexture(croppedTexture, texture.width, texture.height);
        UnityEngine.Object.DestroyImmediate(croppedTexture);
        UnityEngine.Object.DestroyImmediate(texture);
        croppedForegroundRatio = CalculateForegroundRatio(upscaledTexture, backgroundColor, out _, out _, out _, out _);
        return upscaledTexture;
    }

    private static float ScoreCompositionCandidate(Texture2D texture, Color backgroundColor, out bool requiresRetry)
    {
        var foregroundRatio = CalculateForegroundRatio(texture, backgroundColor, out var minX, out var minY, out var maxX, out var maxY);
        if (foregroundRatio <= 0f || maxX < minX || maxY < minY)
        {
            requiresRetry = false;
            return -100f;
        }

        var widthRatio = (maxX - minX + 1f) / texture.width;
        var heightRatio = (maxY - minY + 1f) / texture.height;
        var fillRatio = widthRatio * heightRatio;
        var minMarginRatio = Mathf.Min(
            minX / (float)texture.width,
            minY / (float)texture.height,
            (texture.width - 1 - maxX) / (float)texture.width,
            (texture.height - 1 - maxY) / (float)texture.height);
        var centerX = (minX + maxX + 1f) * 0.5f / texture.width;
        var centerY = (minY + maxY + 1f) * 0.5f / texture.height;
        var centerOffset = Vector2.Distance(new Vector2(centerX, centerY), new Vector2(0.5f, 0.5f));

        var clipped = minMarginRatio < 0.015f || widthRatio > 0.94f || heightRatio > 0.94f;
        var tooLarge = fillRatio > 0.82f || foregroundRatio > 0.58f;
        requiresRetry = clipped || tooLarge;

        var sizeScore = 1f - Mathf.Abs(fillRatio - 0.32f) * 2.5f;
        var marginScore = Mathf.Clamp01(minMarginRatio / 0.07f);
        var centerScore = 1f - Mathf.Clamp01(centerOffset / 0.35f);
        var foregroundScore = 1f - Mathf.Abs(foregroundRatio - 0.22f) * 3f;

        var score = sizeScore * 2.0f + marginScore * 2.5f + centerScore * 1.0f + foregroundScore * 1.5f;
        if (clipped)
        {
            score -= 4f;
        }

        if (tooLarge)
        {
            score -= 2f;
        }

        return score;
    }

    private static float CalculateForegroundRatio(Texture2D texture, Color backgroundColor, out int minX, out int minY, out int maxX, out int maxY)
    {
        minX = texture.width;
        minY = texture.height;
        maxX = -1;
        maxY = -1;
        var pixels = texture.GetPixels32();
        if (pixels == null || pixels.Length == 0)
        {
            return 0f;
        }

        var background = (Color32)backgroundColor;
        var foregroundPixels = 0;
        for (var index = 0; index < pixels.Length; index++)
        {
            var pixel = pixels[index];
            var colorDistance =
                Mathf.Abs(pixel.r - background.r) +
                Mathf.Abs(pixel.g - background.g) +
                Mathf.Abs(pixel.b - background.b);

            if (pixel.a <= 4 || colorDistance < 10)
            {
                continue;
            }

            foregroundPixels++;
            var x = index % texture.width;
            var y = index / texture.width;
            if (x < minX) minX = x;
            if (x > maxX) maxX = x;
            if (y < minY) minY = y;
            if (y > maxY) maxY = y;
        }

        if (foregroundPixels == 0)
        {
            minX = 0;
            minY = 0;
            maxX = -1;
            maxY = -1;
            return 0f;
        }

        return (float)foregroundPixels / pixels.Length;
    }
    private static void RenderPreviewUtility(PreviewRenderUtility previewUtility)
    {
        var renderMethod = typeof(PreviewRenderUtility).GetMethod(
            "Render",
            BindingFlags.Instance | BindingFlags.Public,
            null,
            new[] { typeof(bool) },
            null);

        if (renderMethod != null)
        {
            renderMethod.Invoke(previewUtility, new object[] { true });
            return;
        }

        renderMethod = typeof(PreviewRenderUtility).GetMethod(
            "Render",
            BindingFlags.Instance | BindingFlags.Public,
            null,
            Type.EmptyTypes,
            null);

        if (renderMethod != null)
        {
            renderMethod.Invoke(previewUtility, null);
            return;
        }

        previewUtility.camera.Render();
    }

    private static void FramePreviewCamera(Camera previewCamera, Bounds bounds, float distanceScale)
    {
        FramePreviewCamera(previewCamera, bounds, distanceScale, DefaultPreviewDirection);
    }

    private static void FramePreviewCamera(Camera previewCamera, Bounds bounds, float distanceScale, Vector3 direction)
    {
        var radius = Mathf.Max(bounds.extents.magnitude, 0.05f);
        var normalizedDirection = direction.sqrMagnitude > 0.0001f ? direction.normalized : DefaultPreviewDirection;
        var fieldOfViewRadians = previewCamera.fieldOfView * Mathf.Deg2Rad;
        var distanceFromFov = radius / Mathf.Sin(fieldOfViewRadians * 0.5f);
        var distance = Mathf.Max(distanceFromFov * 1.05f, radius * 1.85f) * distanceScale;
        var target = bounds.center;

        previewCamera.transform.position = target - normalizedDirection * distance;
        previewCamera.transform.LookAt(target);
        previewCamera.nearClipPlane = Mathf.Max(0.01f, distance - radius * 3.5f);
        previewCamera.farClipPlane = distance + radius * 3.5f + 10f;
    }
    private static Bounds CalculateCombinedBounds(Renderer[] renderers)
    {
        var combinedBounds = renderers[0].bounds;
        foreach (var renderer in renderers.Skip(1))
        {
            combinedBounds.Encapsulate(renderer.bounds);
        }

        return combinedBounds;
    }

    private static AnimationClip GetPrimaryAnimationClip(string assetPath)
    {
        return AssetDatabase.LoadAllAssetsAtPath(assetPath)
            .OfType<AnimationClip>()
            .Where(clip => clip != null)
            .Where(clip => !clip.name.StartsWith("__preview__", StringComparison.OrdinalIgnoreCase))
            .OrderByDescending(clip => clip.length)
            .ThenBy(clip => clip.name, StringComparer.OrdinalIgnoreCase)
            .FirstOrDefault();
    }

    private static void SetLayerRecursively(GameObject rootObject, int layer)
    {
        rootObject.layer = layer;
        foreach (Transform child in rootObject.transform)
        {
            SetLayerRecursively(child.gameObject, layer);
        }
    }

    private static int ParsePreviewSize(string rawValue, int fallback)
    {
        int parsedValue;
        if (!string.IsNullOrWhiteSpace(rawValue) && int.TryParse(rawValue, out parsedValue))
        {
            return Mathf.Clamp(parsedValue, 128, 2048);
        }

        if (fallback > 0)
        {
            return Mathf.Clamp(fallback, 128, 2048);
        }

        return DefaultPreviewSize;
    }

    private static string ResolveOutputPath(string outputPath)
    {
        if (string.IsNullOrWhiteSpace(outputPath))
        {
            throw new InvalidOperationException("outputPath was empty.");
        }

        if (IsProjectAssetPath(outputPath))
        {
            var projectRoot = Directory.GetParent(Application.dataPath).FullName;
            return Path.Combine(projectRoot, NormalizePath(outputPath).Replace('/', Path.DirectorySeparatorChar));
        }

        return Path.GetFullPath(outputPath);
    }

    private static bool IsProjectAssetPath(string path)
    {
        return NormalizePath(path).StartsWith("Assets/", StringComparison.OrdinalIgnoreCase);
    }

    private static string NormalizePath(string path)
    {
        return string.IsNullOrWhiteSpace(path) ? string.Empty : path.Replace('\\', '/');
    }

    private static string EscapeCsvValue(string value)
    {
        var normalizedValue = value ?? string.Empty;
        return "\"" + normalizedValue.Replace("\"", "\"\"") + "\"";
    }

    private static string GetCommandLineArgument(IReadOnlyList<string> args, string argumentName)
    {
        for (var index = 0; index < args.Count - 1; index++)
        {
            if (string.Equals(args[index], argumentName, StringComparison.OrdinalIgnoreCase))
            {
                return args[index + 1];
            }
        }

        return string.Empty;
    }
}
