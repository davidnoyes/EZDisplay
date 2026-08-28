//
//  EditDisplayPlistItem.swift
//
//  A menu item that remembers which display it was built for.
//
//  The whole menu is thrown away and rebuilt whenever the displays change, so
//  an item's action cannot look its display up by position in a list that may
//  since have been replaced. Carrying the identifiers on the item itself is
//  what keeps the action pointing at the display the user actually clicked.
//

import Cocoa

@objc class EditDisplayPlistItem: NSMenuItem {
    @objc let vendorID: UInt32
    @objc let productID: UInt32
    @objc let displayName: String

    @objc init(title: String,
               action: Selector,
               vendorID: UInt32,
               productID: UInt32,
               displayName: String) {
        self.vendorID = vendorID
        self.productID = productID
        self.displayName = displayName

        super.init(title: title, action: action, keyEquivalent: "")
    }

    // Every menu in this app is built in code, so there is no archive to decode
    // one of these from.
    required init(coder: NSCoder) {
        fatalError("EditDisplayPlistItem is not loadable from an archive")
    }
}
