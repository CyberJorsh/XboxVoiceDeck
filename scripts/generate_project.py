#!/usr/bin/env python3
"""Generate the dependency-free Xcode project; run after adding source files."""
from pathlib import Path
import hashlib
import json

root = Path(__file__).resolve().parents[1]
project = root / 'XboxVoiceDeck.xcodeproj'
project.mkdir(exist_ok=True)
objects = {}
def ident(key):
    return hashlib.sha256(key.encode()).hexdigest()[:24].upper()
def obj(key, text):
    token = ident(key)
    objects[token] = text
    return token
def q(value):
    return json.dumps(str(value))
def refs(items):
    return '(' + ', '.join(items) + (',' if items else '') + ')'

app_sources = sorted(str(p.relative_to(root)) for p in (root/'XboxVoiceDeck').rglob('*') if p.suffix in ['.swift', '.c'])
test_sources = sorted(str(p.relative_to(root)) for p in (root/'tests').glob('*.swift')) + [p for p in app_sources if not p.endswith('/XboxVoiceDeckApp.swift')]
ui_sources = sorted(str(p.relative_to(root)) for p in (root/'tests'/'UI').glob('*.swift'))
all_paths = sorted(set(app_sources + test_sources + ui_sources + ['XboxVoiceDeck/Audio/Realtime/DeckAudio.h', 'XboxVoiceDeck/Support/BridgingHeader.h', 'XboxVoiceDeck/Support/Info.plist', 'XboxVoiceDeck/Support/XboxVoiceDeck.entitlements']))
file_refs = {}
for path in all_paths:
    kind = {'.swift':'sourcecode.swift','.c':'sourcecode.c.c','.h':'sourcecode.c.h','.plist':'text.plist.xml','.entitlements':'text.plist.entitlements'}[Path(path).suffix]
    file_refs[path] = obj('file:'+path, f'isa = PBXFileReference; lastKnownFileType = {kind}; path = {q(path)}; sourceTree = "<group>";')
products = []
target_ids = []
common = {
 'SDKROOT':'macosx','MACOSX_DEPLOYMENT_TARGET':'14.0','SWIFT_VERSION':'5.0','CLANG_C_LANGUAGE_STANDARD':'gnu11',
 'CLANG_ENABLE_MODULES':'YES','CLANG_ENABLE_OBJC_ARC':'YES','GCC_WARN_64_TO_32_BIT_CONVERSION':'YES',
 'GCC_WARN_ABOUT_RETURN_TYPE':'YES_ERROR','CLANG_WARN_BOOL_CONVERSION':'YES','CLANG_WARN_CONSTANT_CONVERSION':'YES',
 'CLANG_WARN_EMPTY_BODY':'YES','GCC_WARN_UNINITIALIZED_AUTOS':'YES_AGGRESSIVE','GCC_WARN_UNUSED_VARIABLE':'YES',
 'SWIFT_OBJC_BRIDGING_HEADER':'XboxVoiceDeck/Support/BridgingHeader.h',
 'HEADER_SEARCH_PATHS':'$(SRCROOT)/XboxVoiceDeck/Audio/Realtime','ARCHS':'arm64',
 'CODE_SIGN_STYLE':'Manual','CODE_SIGN_IDENTITY':'-','ENABLE_HARDENED_RUNTIME':'YES',
}
def configuration_list(key, extra):
    configs=[]
    for name in ['Debug','Release']:
        settings = dict(common)
        settings.update({'SWIFT_OPTIMIZATION_LEVEL':'-Onone' if name=='Debug' else '-O','GCC_OPTIMIZATION_LEVEL':'0' if name=='Debug' else '3','DEBUG_INFORMATION_FORMAT':'dwarf-with-dsym','ENABLE_TESTABILITY':'YES' if name=='Debug' else 'NO'})
        settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = 'DEBUG' if name == 'Debug' else ''
        settings.update(extra)
        body=' '.join(f'{k} = {q(v)};' for k,v in settings.items())
        configs.append(obj(key+name, f'isa = XCBuildConfiguration; buildSettings = {{ {body} }}; name = {name};'))
    return obj(key+'configlist', f'isa = XCConfigurationList; buildConfigurations = {refs(configs)}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')

for name, paths, kind in [('XboxVoiceDeck',app_sources,'application'),('XboxVoiceDeckTests',test_sources,'bundle.unit-test'),('XboxVoiceDeckUITests',ui_sources,'bundle.ui-testing')]:
    is_test = kind != 'application'
    is_ui = kind == 'bundle.ui-testing'
    builds=[obj(name+':build:'+p, f'isa = PBXBuildFile; fileRef = {file_refs[p]};') for p in paths]
    sources=obj(name+':sources',f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = {refs(builds)}; runOnlyForDeploymentPostprocessing = 0;')
    frameworks=[]
    for fw in ['CoreAudio','AudioToolbox','AVFoundation','SwiftUI','AppKit']:
        fr=obj('framework:'+fw, f'isa = PBXFileReference; lastKnownFileType = wrapper.framework; name = {fw}.framework; path = System/Library/Frameworks/{fw}.framework; sourceTree = SDKROOT;')
        frameworks.append(obj(name+':frameworkbuild:'+fw,f'isa = PBXBuildFile; fileRef = {fr};'))
    fp=obj(name+':frameworks',f'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = {refs(frameworks)}; runOnlyForDeploymentPostprocessing = 0;')
    product=obj(name+':product',f'isa = PBXFileReference; explicitFileType = {"wrapper.cfbundle" if is_test else "wrapper.application"}; includeInIndex = 0; path = {name + (".xctest" if is_test else ".app")}; sourceTree = BUILT_PRODUCTS_DIR;')
    products.append(product)
    extra={'PRODUCT_NAME':name, 'PRODUCT_BUNDLE_IDENTIFIER':'com.justjorshin.'+name}
    if is_test:
        extra.update({'GENERATE_INFOPLIST_FILE':'YES','LD_RUNPATH_SEARCH_PATHS':'$(inherited) @loader_path/../Frameworks @executable_path/../Frameworks','ENABLE_HARDENED_RUNTIME':'NO'})
    else:
        extra.update({'INFOPLIST_FILE':'XboxVoiceDeck/Support/Info.plist','CODE_SIGN_ENTITLEMENTS':'XboxVoiceDeck/Support/XboxVoiceDeck.entitlements','LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/../Frameworks'})
    if is_ui:
        extra.update({'TEST_TARGET_NAME':'XboxVoiceDeck', 'SWIFT_OBJC_BRIDGING_HEADER':''})
    dependencies = []
    if is_ui:
        proxy = obj(name+':proxy', f'isa = PBXContainerItemProxy; containerPortal = {ident("project")}; proxyType = 1; remoteGlobalIDString = {target_ids[0]}; remoteInfo = XboxVoiceDeck;')
        dependencies.append(obj(name+':dependency', f'isa = PBXTargetDependency; target = {target_ids[0]}; targetProxy = {proxy};'))
    cl=configuration_list(name,extra)
    target_ids.append(obj(name+':target',f'isa = PBXNativeTarget; buildConfigurationList = {cl}; buildPhases = {refs([sources,fp])}; buildRules = (); dependencies = {refs(dependencies)}; name = {name}; productName = {name}; productReference = {product}; productType = "com.apple.product-type.{kind}";'))
pg=obj('products',f'isa = PBXGroup; children = {refs(products)}; name = Products; sourceTree = "<group>";')
group=obj('main',f'isa = PBXGroup; children = {refs(list(file_refs.values())+[pg])}; sourceTree = "<group>";')
cl=configuration_list('project',{})
project_id=obj('project',f'isa = PBXProject; attributes = {{ LastUpgradeCheck = 2700; }}; buildConfigurationList = {cl}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base); mainGroup = {group}; productRefGroup = {pg}; projectDirPath = ""; projectRoot = ""; targets = {refs(target_ids)};')
text='// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'
text+='\n'.join(f'{key} = {{ {value} }};' for key,value in objects.items())
text+=f'\n}}; rootObject = {project_id}; }}\n'
(project/'project.pbxproj').write_text(text)
scheme=project/'xcshareddata/xcschemes/XboxVoiceDeck.xcscheme'
scheme.parent.mkdir(parents=True,exist_ok=True)
def buildref(index,name,product):
    return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target_ids[index]}" BuildableName="{product}" BlueprintName="{name}" ReferencedContainer="container:XboxVoiceDeck.xcodeproj"/>'
a=buildref(0,'XboxVoiceDeck','XboxVoiceDeck.app')
t=buildref(1,'XboxVoiceDeckTests','XboxVoiceDeckTests.xctest')
u=buildref(2,'XboxVoiceDeckUITests','XboxVoiceDeckUITests.xctest')
scheme.write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.7">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{a}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{t}</TestableReference><TestableReference skipped="NO">{u}</TestableReference></Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="NO"><BuildableProductRunnable runnableDebuggingMode="0">{a}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{a}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''')
print('Generated',project)
