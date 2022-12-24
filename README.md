# TJMixpanelLogger

`TJMixpanelLogger` is a bare-bones Objective-C [Mixpanel](https://mixpanel.com) logger. It only provides event logging, not user logging or other features that Mixpanel provides.

## Setup & Use

To configure `TJMixpanelLogger`, set its `projectToken` to your Mixpanel project's project token.

```objc
TJMixpanelLogger.projectToken = @"your-token-here";
```

If you'd like to use `TJMixpanelLogger` within app extensions, you should also set its `sharedContainerIdentifier` property to an app group identifier.

```objc
TJMixpanelLogger.sharedContainerIdentifier = @"an-app-group-identifier";
```

To log an event with `TJMixpanelLogger`, use the `+logEventWithName:properties:` method.

```objc
[TJMixpanelLogger logEventWithName:@"photo_shared"
                        properties: @{
    @"source": @"camera"
    @"width": ...
}];
```

## Default Event Properties

Events logged using `TJMixpanelLogger` automatically capture the following info.

- A base 64 version of `identifierForVendor` as the install identifier.
- The app version string.
- The OS version.
- The device model.
- The screen dimensions.
- Coarse IP-based location.
- The preferred language.
- For app extensions, the suffix of the extension is included as `bundle_id_suffix`. Apps including extensions will have `bundle_id_suffix=null` for events from the main app.

## Other Notes

- This logger supports app extensions (needed for [Opener](https://apps.apple.com/app/id989565871) and [Checkie](https://apps.apple.com/app/id382356167)).
- This logger supports watchOS (needed for [Checkie](https://apps.apple.com/app/id382356167)).
- This logger uses background URL sessions.
- This is the successor to a custom Google Analytics logger I've been using for a while ([very old source snapshot](https://gist.github.com/timonus/2869183a4442e2e70ff9)).