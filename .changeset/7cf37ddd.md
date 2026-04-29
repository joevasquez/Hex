---
"hex-app": patch
---

Fix iOS keychain read: API keys saved in Settings weren't being found by photo analysis (kSecAttrAccessible shouldn't be in lookup queries)
