//
//  UIImageExtension.swift
//  Beets
//
//  Created by Aditya Sawhney on 10/4/16.
//  Copyright © 2016 Druid, LLC. All rights reserved.
//

import Foundation
import UIKit

extension UIImage {
    
    /**
     Convenience method to load in 20-frame animations from xcassets.
     */
    class func animationImageSet(withPrefix prefix: String) -> [UIImage]? {
        var images = [UIImage]()
        for i in 0..<20 {
            images.append(UIImage(named:"\(prefix)Animation-\(i)")!)
        }
        return images.count > 0 ? images : nil
    }
    
}
