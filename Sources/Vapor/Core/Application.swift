import Foundation

#if os(Linux)
	import Glibc
#endif

public class Application {
	public static let VERSION = "0.2.5"

	/**
		The router driver is responsible
		for returning registered `Route` handlers
		for a given request.
	*/
	public let router: RouterDriver

	/**
		The server driver is responsible
		for handling connections on the desired port.
		This property is constant since it cannot
		be changed after the server has been booted.
	*/
	public var server: ServerDriver

	/**
		`Middleware` will be applied in the order
		it is set in this array.

		Make sure to append your custom `Middleware`
		if you don't want to overwrite default behavior.
	*/
	public var middleware: [Middleware.Type]


	/**
		Provider classes that have been registered
		with this application
	*/
    public var providers: [Provider.Type]

	/**
		Internal value populated the first time
		self.environment is computed
	*/
	private var detectedEnvironment: String?

	/**
		Current environment of the application
	*/
	public var environment: String {
		if let environment = self.detectedEnvironment {
			return environment
		}

		let environment = self.bootEnvironment()
		self.detectedEnvironment = environment
		return environment
	}

	/**
		Optional handler to be called when determing the
		current environment.
	*/
	public var detectEnvironmentHandler: ((String) -> String)?

	/**
		The work directory of your application is
		the directory in which your Resources, Public, etc
		folders are stored. This is normally `./` if
		you are running Vapor using `.build/xxx/App`
	*/
	public static var workDir = "./" {
		didSet {
			if !self.workDir.hasSuffix("/") {
				self.workDir += "/"
			}
		}
	}
    
    var routes: [Route] = []

	/**
		Initialize the Application.
	*/
    public init(router: RouterDriver = BranchRouter(), server: ServerDriver = SocketServer()) {
        self.server = server
        self.router = router

        self.middleware = [
            AbortMiddleware.self
        ]
        
        self.providers = []
        
        self.middleware.append(SessionMiddleware)
	}

    
    public func bootProviders() {
        for provider in self.providers {
            provider.boot(self)
        }
    }
    
    func bootRoutes() {
        routes.forEach(router.register)
    }

	func bootEnvironment() -> String {
		var environment: String

		if let value = self.argument("env") {
			environment = value
		} else {
			// TODO: This should default to "production" in release builds
			environment = "local"
		}

		if let handler = self.detectEnvironmentHandler {
			environment = handler(environment)
		}

		return environment
	}

	/**
		If multiple environments are passed, return
		value will be true if at least one of the passed
		in environment values matches the app environment
		and false if none of them match.

		If a single environment is passed, the return
		value will be true if the the passed in environment
		matches the app environment.
	*/
	public func inEnvironment(environments: String...) -> Bool {
		if environments.count == 1 {
			return self.environment == environments[0]
		} else {
			return environments.contains(self.environment)
		}
	}

    /**
        Returns the string value of an
        argument passed to the executable
        in the format --name=value
    */
    func argument(name: String) -> String? {
        for argument in Process.arguments {
            if argument.hasPrefix("--\(name)=") {
                return argument.split("=")[1]
            }
        }
        
        return nil
    }

	/**
		Boots the chosen server driver and
		runs on the supplied port.
	*/
	public func start(port inPort: Int = 80) {
        self.bootProviders()
        self.server.delegate = self
        
        self.bootRoutes()

		var port = inPort

		//grab process args
        if let workDir = self.argument("workDir") {
            print("Work dir override: \(workDir)")
            self.dynamicType.workDir = workDir
        }
        
        if let portString = self.argument("port") {
            if let portInt = Int(portString) {
                print("Port override: \(portInt)")
                port = portInt
            }
        }


		do {
			try self.server.boot(port: port)

			print("Server has started on port \(port)")

			self.loop()
		} catch {
			print("Server start error: \(error)")
		}
	}

	/**
		Starts an infinite loop to keep the server alive while it
		waits for inbound connections.
	*/
	func loop() {
		#if os(Linux)
			while true {
				sleep(1)
			}
		#else
			NSRunLoop.mainRunLoop().run()
		#endif
	}
}

extension Application: ServerDriverDelegate {

	public func serverDriverDidReceiveRequest(request: Request) -> Response {
		var handler: Request.Handler

		// Check in routes
		if let routerHandler = router.route(request) {
			handler = routerHandler
		} else {
			// Check in file system
			let filePath = self.dynamicType.workDir + "Public" + request.path

			let fileManager = NSFileManager.defaultManager()
			var isDir: ObjCBool = false

			if fileManager.fileExistsAtPath(filePath, isDirectory: &isDir) {
				// File exists
				if let fileBody = NSData(contentsOfFile: filePath) {
					var array = [UInt8](count: fileBody.length, repeatedValue: 0)
					fileBody.getBytes(&array, length: fileBody.length)

					return Response(status: .OK, data: array, contentType: .Text)
				} else {
					handler = { _ in
                        Log.warning("Could not open file, returning 404")
						return Response(status: .NotFound, text: "Page not found")
					}
				}
			} else {
				// Default not found handler
				handler = { _ in
					return Response(status: .NotFound, text: "Page not found")
				}
			}
		}

		// Loop through middlewares in order
		for middleware in self.middleware {
			handler = middleware.handle(handler)
		}

        do {
            let response = try handler(request: request)

            if response.headers["Content-Type"] == nil {
            	Log.warning("Response had no 'Content-Type' header.")
            }

            return response
        } catch {
            return Response(error: "Server Error: \(error)")
        }

	}

}
